//
//  E2EAsyncImageCorruptionTests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the async-image-corruption fix: a
//  plain inline ProseMirror `image` node (as opposed to this app's custom
//  `figure` node) never got the media/... -> projectmedia://... display-URL
//  rewrite it needs to render, showing a permanent broken-image icon. Root
//  mechanism: `insertImage()` always creates a `figure` node at insert time
//  (renders fine immediately); the degradation to a plain `image` node
//  happens on a LATER save->reparse cycle (figure's markdown serializes as a
//  bare image line with no blank-line separation, which remerges into
//  surrounding text on reparse and fails the figure-promotion gate in
//  image-plugin.ts's remarkFigurePlugin). The fix is two-part:
//    1. image-node-rewrite-plugin.ts -- a schema-level toDOM/parseDOM
//       override so a plain `image` node gets the same media/... rewrite
//       FigureNodeView already applies, plus a data-src round-trip so a
//       stray DOM mutation reconciliation can't overwrite the canonical
//       media/... value with the rewritten display value.
//    2. block-sync-plugin.ts's serializeInlineContent() -- previously had no
//       case for a plain `image` node, so it fell through to a generic
//       fallback that silently dropped the image reference from the
//       persisted markdownFragment whenever a block containing one got
//       touched by a live edit.
//
//  Rather than simulating real OS-level drag-and-drop or clipboard paste
//  (unreliable/hard to automate for a WKWebView editor -- see
//  docs/guides/testing-architecture.md), this test builds a fixture that is
//  ALREADY in the corrupted/degraded shape: a paragraph containing text +
//  a mid-paragraph plain `image` node with a media/-prefixed src, mixed with
//  real text on both sides -- exactly the shape a real paste/drop degrades
//  into after a save/reparse cycle, and exactly the shape
//  PLAIN_PARAGRAPH_MID_IMAGE_MD exercises in
//  web/milkdown/src/__tests__/image-node-rewrite.test.ts. This directly
//  tests "does the real app render this correctly when opened" without
//  needing to reproduce the multi-step degradation sequence that produces
//  it in the wild.
//
//  Fixture strategy: the committed `test-fixture.ff`'s `block` table is
//  empty at rest (TestFixtureFactory populates content.markdown but the
//  committed snapshot predates block backfill), so on load
//  ContentView+ProjectLifecycle.swift's `existingBlocks.isEmpty` branch fires
//  and `content.markdown` (the `content` table) is the SOLE source of the
//  editor's initial DOM shape -- confirmed by tracing that load path before
//  writing this test. So the doctoring step below edits `content.markdown`
//  directly via the sqlite3 CLI (same unsandboxed-subprocess pattern
//  ListNumberingE2ETests.swift already uses for read queries, used here for
//  a write instead) on a copy of the fixture, appending a corrupted
//  mid-paragraph image paragraph AND a standalone (figure-promotable) image
//  paragraph, plus writing two tiny real PNG files into the copy's `media/`
//  directory (MediaSchemeHandler.swift serves images straight from disk by
//  filename, so a real file must exist there or the `projectmedia://`
//  request 404s regardless of whether the rewrite fix works).
//
//  Export coverage: the plan asked for an "Export unaffected" check if
//  reasonably testable. Skipped as a full UI-driven export flow (File >
//  Export goes through a native NSSavePanel) because it would add
//  significant flakiness for coverage this suite already gets for free.
//  Block.swift's markdownForExport()/markdownForStandardExport() only apply
//  image-specific rewriting when `blockType == .image`; our mid-paragraph
//  corruption is `blockType == .paragraph` (confirmed against
//  BlockParser.swift's `.image` classification, which requires the trimmed
//  block to literally START with `![`), so for this block type both export
//  functions return `markdownFragment` verbatim -- meaning
//  testMidParagraphImageSurvivesLiveEditRoundtrip()'s direct assertion on
//  the persisted `markdownFragment` (canonical `media/...`, never
//  `projectmedia://...`) already IS the export-correctness proof; a full
//  NSSavePanel-driven export would only be re-checking the same string a
//  second time through more UI surface area.
//
//  Delete this file once its evidence has been captured -- it is disposable
//  verification scaffolding, not a permanent regression test. Permanent
//  coverage for the underlying fix already exists at the unit level in
//  web/milkdown/src/__tests__/image-node-rewrite.test.ts (rendering) and
//  web/milkdown/src/__tests__/block-sync-marks.test.ts (persistence).
//

import AppKit
import XCTest

final class E2EAsyncImageCorruptionTests: XCTestCase {
    var app: XCUIApplication!

    // MARK: - Doctored content constants

    private static let standaloneImageFilename = "standalone-image.png"
    private static let standaloneImageAlt = "a standalone regression photo"
    private static let midImageFilename = "test-image.png"
    private static let midImageAlt = "a corrupted test photo"

    /// Substring present in both the "before" and "after" text runs
    /// surrounding the mid-paragraph image -- used for the DB LIKE query.
    private static let midParagraphMarker = "corrupted paragraph marker"
    /// Full text of the leading run (before the inline image), for an exact
    /// accessibility subscript lookup -- see the click-target comment in
    /// testMidParagraphImageSurvivesLiveEditRoundtrip() for why this must be
    /// a complete-string match rather than a substring predicate, and why the
    /// trailing space is significant (it's part of the run's real text, per a
    /// real debugDescription dump).
    private static let midParagraphClickText = "Corrupted paragraph marker before the inline photo "

    /// A minimal, real, decodable 1x1 PNG (68 bytes). Content is irrelevant --
    /// only that WKWebView can actually decode+paint it, since a broken-image
    /// icon would prove the opposite of what this test exists to show.
    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    /// Appended verbatim to the fixture's existing content.markdown. Mirrors
    /// image-node-rewrite.test.ts's PLAIN_PARAGRAPH_MID_IMAGE_MD shape
    /// ("Before text ![alt](media/test.png) after text.") for the corrupted
    /// case, plus a standalone image line (blank-line separated, single
    /// child of its paragraph) that image-plugin.ts's remarkFigurePlugin
    /// SHOULD still promote to a `figure` node -- the regression guard.
    private static var appendixMarkdown: String {
        """


        ## Image Regression Section

        Standalone image below should still promote to a figure and render correctly.

        ![\(standaloneImageAlt)](media/\(standaloneImageFilename))

        Corrupted paragraph marker before the inline photo ![\(midImageAlt)](media/\(midImageFilename)) and corrupted paragraph marker after the inline photo.
        """
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication.targetApp()
        app.terminate()

        try TestFixtureHelper.setupFixture(from: self)
        try Self.doctorFixture(at: TestFixtureHelper.fixturePath)

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Test 1: reload/degraded-state rendering (the key proof)

    /// Proves the render half of the fix: a fixture that is ALREADY in the
    /// corrupted shape (mid-paragraph plain `image` node) renders correctly
    /// on open, not as a permanent broken-image icon. Also guards that a
    /// normal standalone image still promotes to and renders as a `figure`
    /// (the fix must not regress the common case).
    func testDoctoredFixtureRendersBothImageShapes() throws {
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistenceOrFail(timeout: 10).exists,
                      "Editor area should appear with the doctored fixture's content")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10),
                      "Word count should appear before evidence capture (editor JS is ready)")

        // Let the WYSIWYG editor's remark parse + image decode settle.
        Thread.sleep(forTimeInterval: 1.5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "doctored-fixture-initial-render"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Best-effort DOM-level signal: WKWebView commonly exposes <img alt="…">
        // elements as native AX "Image" elements keyed by alt text, but there
        // is no existing precedent anywhere in this suite querying
        // app.images against this app's WKWebView content (see
        // docs/guides/testing-architecture.md's "cannot inspect internal
        // state" caveat), so this is corroborating evidence only -- logged,
        // not asserted on. The screenshot above and the DB-persistence
        // assertion in testMidParagraphImageSurvivesLiveEditRoundtrip() are
        // the hard proof for this test class.
        let midImageFound = app.images[Self.midImageAlt].waitForExistence(timeout: 5)
        let standaloneImageFound = app.images[Self.standaloneImageAlt].waitForExistence(timeout: 5)
        print("[E2EAsyncImageCorruptionTests] AX image lookup (best-effort): " +
              "mid-paragraph found=\(midImageFound), standalone found=\(standaloneImageFound)")

        // Deterministic proof that both images survived the load parse
        // (Swift's own BlockParser, run synchronously at load time against
        // the same content.markdown the WYSIWYG editor rendered -- see
        // ContentView+ProjectLifecycle.swift) with the correct block-type
        // classification: the mid-paragraph image must stay part of a plain
        // `paragraph` block (proving the figure-promotion gate correctly
        // rejected it, i.e. this really is the corrupted shape under test),
        // while the standalone image must classify as its own `image` block
        // (the regression guard).
        let allBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2EAsyncImageCorruptionTests] DIAGNOSTIC all blocks after load:\n\(allBlocks.joined(separator: "\n---\n"))")

        XCTAssertTrue(
            allBlocks.contains { $0.hasPrefix("paragraph:") && $0.contains(Self.midImageFilename) },
            "Expected a paragraph block containing the mid-paragraph image reference. All blocks: \(allBlocks)"
        )
        XCTAssertTrue(
            allBlocks.contains { $0.hasPrefix("image:") && $0.contains(Self.standaloneImageFilename) },
            "Expected the standalone image line to classify as its own image block (figure regression guard). All blocks: \(allBlocks)"
        )
    }

    // MARK: - Test 2: DB persistence through a live edit (block-sync-plugin.ts fix)

    /// Proves the persistence half of the fix: after a genuine live edit
    /// touches the block containing the mid-paragraph image, the JS-side
    /// incremental block-sync path (block-sync-plugin.ts's
    /// serializeInlineContent(), polled by BlockSyncService.swift every 2s)
    /// must still emit the image reference in the block's persisted
    /// markdownFragment -- not silently drop it, which was the DB-corruption
    /// half of this bug. The inserted character is asserted present in the
    /// post-edit fragment specifically so a false pass (e.g. a misdirected
    /// click that never actually reaches the JS live-sync path, leaving the
    /// DB showing only the untouched load-time value) can't slip through.
    func testMidParagraphImageSurvivesLiveEditRoundtrip() throws {
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistenceOrFail(timeout: 10).exists,
                      "Editor area should appear with the doctored fixture's content")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10),
                      "Word count should appear before interacting with the editor")

        // This app's WKWebView-hosted paragraph text (ProseMirror/Milkdown
        // contenteditable) exposes its text via the accessibility VALUE
        // attribute, not LABEL -- confirmed via a real debugDescription dump
        // (every text-bearing StaticText here prints "value: ...", never
        // "label: ..."), so an NSPredicate matching against `label` (the
        // original approach) always finds zero matches regardless of
        // substring. A `value CONTAINS[c]` predicate isn't a safe fix either:
        // a real run showed it throws "Can't use in/contains operator with
        // collection 1 (not a collection)" because sibling StaticTexts in the
        // same query (e.g. the "Test Document" H1's heading-level indicator)
        // have a non-string `value` (an NSNumber), which CONTAINS can't
        // evaluate. The inline image also splits this paragraph into two
        // separate StaticText elements at the image boundary (confirmed via
        // the same dump), so the exact text of the leading run is needed --
        // that's what midParagraphClickText holds. Exact-match subscript
        // lookup (not a substring predicate) is the same established, working
        // convention ListNumberingE2ETests.swift already uses for this app's
        // WKWebView editor text (e.g. app.staticTexts["Second item"],
        // app.staticTexts["More content here."]).
        let clickTarget = app.staticTexts[Self.midParagraphClickText]
        XCTAssertTrue(clickTarget.waitForExistence(timeout: 10),
                      "The mid-paragraph corrupted text should be visible and reachable via accessibility")

        // A click anywhere inside this paragraph's own text is sufficient --
        // block-sync diffs at the whole top-level-block granularity, so the
        // edit doesn't need to land adjacent to the image itself, only
        // somewhere inside the SAME block. Coordinate-based click (not a bare
        // `.click()`) to match this suite's established real-mouse-event
        // convention (see ListNumberingE2ETests.swift).
        let clickPoint = clickTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        clickPoint.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeText("Z")

        // Let the JS-side 100ms debounce (block-sync-plugin.ts) and Swift's
        // 2s poll (BlockSyncService.pollInterval) both land, with margin.
        Thread.sleep(forTimeInterval: 4.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mid-paragraph-image-after-live-edit"
        attachment.lifetime = .keepAlways
        add(attachment)

        let allBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2EAsyncImageCorruptionTests] DIAGNOSTIC all blocks after edit:\n\(allBlocks.joined(separator: "\n---\n"))")

        let matchingFragments = try Self.queryBlockMarkdownFragments(
            fixturePath: TestFixtureHelper.fixturePath,
            like: "%\(Self.midParagraphMarker)%"
        )

        XCTAssertEqual(
            matchingFragments.count, 1,
            "Expected exactly one block matching the mid-paragraph marker text. All blocks: \(allBlocks)"
        )
        guard let fragment = matchingFragments.first else { return }

        XCTAssertTrue(
            fragment.contains("Z"),
            "BUG (test setup, not product): the typed edit never reached the persisted block -- " +
            "this run doesn't actually exercise the live-sync path. Fragment: \(fragment)"
        )
        XCTAssertTrue(
            fragment.contains("media/\(Self.midImageFilename)"),
            "BUG: the image reference was dropped from the persisted markdownFragment after a live edit " +
            "touched its block -- this is exactly the block-sync-plugin.ts data-loss bug the fix addresses. " +
            "Fragment: \(fragment)"
        )
        XCTAssertFalse(
            fragment.contains("projectmedia://"),
            "BUG: the rewritten DISPLAY url leaked into persisted storage instead of the canonical media/... " +
            "value -- this is exactly the parseDOM data-loss risk image-node-rewrite-plugin.ts's data-src " +
            "split exists to prevent. Fragment: \(fragment)"
        )
    }

    // MARK: - Fixture doctoring

    /// Copies two tiny real PNG files into the fixture copy's `media/`
    /// directory (MediaSchemeHandler.swift reads straight from disk by
    /// filename -- a missing file 404s regardless of whether the URL-rewrite
    /// fix works, which would make this test pass or fail for the wrong
    /// reason), then appends the corrupted + standalone image markdown to
    /// `content.markdown` via a raw sqlite3 UPDATE. Must run BEFORE
    /// `app.launch()` -- this mutates the fixture copy's `content` table
    /// directly, on disk, while nothing has the database open.
    private static func doctorFixture(at fixturePath: String) throws {
        let fm = FileManager.default
        let mediaDir = URL(fileURLWithPath: fixturePath).appendingPathComponent("media")
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        guard let pngData = Data(base64Encoded: tinyPNGBase64) else {
            XCTFail("Failed to decode embedded test PNG from base64")
            return
        }
        try pngData.write(to: mediaDir.appendingPathComponent(midImageFilename))
        try pngData.write(to: mediaDir.appendingPathComponent(standaloneImageFilename))

        FixtureDatabase.seedMarkdown(fixturePath: fixturePath, markdown: appendixMarkdown, appending: true)

        print("[E2EAsyncImageCorruptionTests] Doctored fixture content.markdown + media/ at: \(fixturePath)")
    }

    /// Escapes a string for embedding as a single-quoted SQLite string
    /// literal (doubles any embedded single quotes). `appendixMarkdown`
    /// currently contains none, but this keeps the helper correct if the
    /// constant above ever changes.
    private static func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - DB query helpers
    //
    // Same unsandboxed-subprocess-via-sqlite3-CLI pattern as
    // ListNumberingE2ETests.swift's identically-named helpers (the XCUITest
    // runner process is unsandboxed, same as this project's existing
    // Process()-based tests in final finalTests/Tier2/).

    private static func queryBlockMarkdownFragments(fixturePath: String, like pattern: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let escapedPattern = sqlEscape(pattern)
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block WHERE markdownFragment LIKE '\(escapedPattern)' ORDER BY sortOrder;"

        let (stdout, stderr, status) = try runSqlite3(dbPath: dbPath, sql: sql)
        if status != 0 {
            XCTFail("sqlite3 query failed (status \(status)): \(stderr)")
        }

        return stdout
            .components(separatedBy: "\(sentinel)\n")
            .filter { !$0.isEmpty }
    }

    /// Dumps `blockType: markdownFragment` for every row, in document order --
    /// distinguishes "doctoring never landed" (zero/wrong rows) from
    /// "doctoring landed but classification differs from expectation".
    private static func queryAllBlocks(fixturePath: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT blockType || ': ' || markdownFragment || '\(sentinel)' FROM block ORDER BY sortOrder;"

        let (stdout, _, _) = try runSqlite3(dbPath: dbPath, sql: sql)
        return stdout
            .components(separatedBy: "\(sentinel)\n")
            .filter { !$0.isEmpty }
    }

    private static func runSqlite3(dbPath: String, sql: String) throws -> (stdout: String, stderr: String, status: Int32) {
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
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }
}
