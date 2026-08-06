//
//  ListNumberingE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the numbered-list-restart fix:
//  an automatic split (image paste mid-list) must CONTINUE numbering,
//  while a deliberate, user-initiated new list must still restart at 1.
//  Drives the real macOS app via XCUITest -- real clipboard paste, real
//  keyboard shortcuts, real Swift+WebKit bridge -- per the e2e-verify skill.
//
//  Content-correctness caveat: per docs/guides/testing-architecture.md,
//  XCUITest "cannot inspect internal state or cross-process content" from a
//  WKWebView -- there is no precedent anywhere in this suite for reading
//  Milkdown/CodeMirror's rendered DOM text back through the accessibility
//  tree, and CodeMirror's virtualized `cm-line` divs make that especially
//  unreliable. Instead of trying to add that, this test uses Cmd+/ (Source
//  Mode toggle) for its DOCUMENTED side effect of calling
//  flushContentToDatabase() ("Called before zoom-out, zoom-to, and editor
//  switch to ensure edits are saved" -- EditorViewState+Zoom.swift), which
//  parses the live WYSIWYG content into `block` rows via BlockParser. It then
//  reads those rows directly from the fixture's on-disk content.sqlite (the
//  app's documented single source of truth) via the sqlite3 CLI. This proves
//  the fix end-to-end (UI action -> bridge -> parse -> persisted block) with
//  a ground truth that doesn't depend on accessibility-tree text extraction.
//
//  Delete this file once its evidence has been captured -- it is disposable
//  verification scaffolding, not a permanent regression test.
//

import AppKit
import XCTest

final class ListNumberingE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication.targetApp()
        app.terminate()

        try TestFixtureHelper.setupFixture(from: self)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Case 1: automatic split (image paste mid-list) continues numbering

    func testImagePasteMidListContinuesNumbering() throws {
        Self.focusEditorAndGoToDocumentEnd(app: app, testCase: self)

        // Append a fresh, known 3-item ordered list after the fixture's
        // existing content. Typing "1. " triggers Milkdown's ordered-list
        // input rule; Return continues the list without retyping numbers.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("1. First item")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Second item")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Third item")
        Thread.sleep(forTimeInterval: 0.3)

        // Click directly at the START of "Second item"'s own rendered text
        // (a real mouse event on a real AX element, not a synthetic
        // upArrow+home key sequence) -- a normal click position at the start
        // of a non-first list item, exactly the scenario proven against the
        // real editor pipeline in
        // web/milkdown/src/__tests__/repro-list-paste.test.ts (item2Pos).
        // Two earlier arrow-key-based attempts were unreliable: real runs
        // showed dropped upArrow/home keystrokes landing the caret on the
        // wrong item (evidenced by the split happening one item later than
        // intended). Milkdown's WYSIWYG rendering exposes each list item's
        // text as its own accessible StaticText element (confirmed via a
        // real debugDescription dump), so a direct coordinate click on it
        // sidesteps keyboard-navigation flakiness entirely.
        let secondItemText = app.staticTexts["Second item"]
        XCTAssertTrue(secondItemText.waitForExistence(timeout: 10), "'Second item' list item should be visible and reachable via accessibility")
        let startOfSecondItem = secondItemText.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        startOfSecondItem.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 0.3)

        // Real clipboard image, real Cmd+V -- not a synthetic ClipboardEvent.
        Self.putTestImageOnPasteboard()
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: .command)

        // Let the async image import (NSImage -> temp file -> JS insertImage
        // -> ProseMirror transaction) settle. No clean AX signal exists for
        // "image finished inserting" (see file header), so this is a bounded
        // real-world wait, not a busy-poll.
        Thread.sleep(forTimeInterval: 2.5)

        // Trigger the Source Mode toggle -- see file header for why this is
        // also our signal to flush WYSIWYG content into `block` rows.
        // Note: the accessibility LABEL flips to "Source" as soon as the
        // toggle is issued, but the actual WYSIWYG->CodeMirror view swap is
        // driven by an async cursor-save callback chain that
        // `EditorSmokeTests.testEditorModeToggle` already documents as "not
        // completing reliably in XCUITest" -- a real run's screenshot
        // confirmed this: still WYSIWYG-rendered at capture time despite the
        // label already reading "Source". That's harmless here because the
        // actual proof (below) reads persisted `block` rows, not pixels --
        // but it does mean this screenshot is best-effort visual context
        // (still shows the real, correctly-continued 1/2/3 numbering and the
        // real inserted image), not literal Source Mode markdown.
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(editorMode.waitForLabel("== 'Source'", timeout: 10), "Editor-mode button should report Source (triggers the flush; view swap itself may lag -- see comment above)")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "image-paste-mid-list-after-toggle"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Give the flush + BlockSyncService poll a moment to land on disk.
        Thread.sleep(forTimeInterval: 1.5)

        let allBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[ListNumberingE2ETests] DIAGNOSTIC all blocks after paste+toggle:\n\(allBlocks.joined(separator: "\n---\n"))")

        let fragments = try Self.queryBlockMarkdownFragments(
            fixturePath: TestFixtureHelper.fixturePath,
            blockType: "ordered_list"
        )

        XCTAssertEqual(
            fragments.count, 2,
            "Expected the list to split into two ordered_list blocks around the pasted image. Got: \(fragments). All blocks: \(allBlocks)"
        )
        guard fragments.count == 2 else { return }

        let firstHalf = fragments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let secondHalf = fragments[1].trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(firstHalf.contains("First item"), "First half should contain 'First item'. Got: \(firstHalf). All blocks: \(allBlocks)")
        XCTAssertTrue(firstHalf.hasPrefix("1."), "First half should start at 1. Got: \(firstHalf). All blocks: \(allBlocks)")

        XCTAssertTrue(
            secondHalf.contains("Second item") && secondHalf.contains("Third item"),
            "Second half should contain both remaining items. Got: \(secondHalf). All blocks: \(allBlocks)"
        )
        XCTAssertFalse(
            secondHalf.hasPrefix("1."),
            "BUG: second half restarted numbering at 1 instead of continuing. Got: \(secondHalf). All blocks: \(allBlocks)"
        )
        XCTAssertTrue(
            secondHalf.hasPrefix("2."),
            "Second half should continue numbering at 2. Got: \(secondHalf). All blocks: \(allBlocks)"
        )
    }

    // MARK: - Case 2: deliberate new list restarts at 1

    func testDeliberateNewListRestartsAtOne() throws {
        Self.focusEditorAndGoToDocumentEnd(app: app, testCase: self)

        // Plain prose paragraph, then a deliberately-typed, standalone new
        // ordered list -- no paste/split involved. This is the control case:
        // the fix must NOT force a continuation value onto a genuinely new list.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Some prose before a fresh list.")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("1. Alpha item")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Beta item")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Gamma item")

        // Quiesce before triggering the flush below. This is a REAL
        // quiescence check on data that already exists, not a wait for the
        // toggle itself to create it: BlockSyncService's periodic poll
        // (BlockSyncService.swift, 2s Timer, gated on `contentState == .idle`)
        // keeps running throughout ordinary typing -- typing never moves
        // `contentState` off `.idle` (that only happens for zoom, mode
        // switch, bibliography update, drag-reorder, etc., none of which are
        // in play here) -- so by the time we reach this line, the periodic
        // poll has almost certainly already fired at least once and persisted
        // the `ordered_list` row from the typing above. Cmd+/'s own flush
        // (below) is not what first puts this row in the `block` table. What
        // this poll still guards against is the app's periodic Swift<->JS
        // sync possibly being mid-write when we read: it polls (bounded at
        // 10s) until an ordered_list row exists and is byte-identical across
        // two reads 1s apart, rather than assuming typing has already settled
        // by the time we reach here. See waitForStableOrderedList's doc
        // comment for what this does and doesn't guard against.
        let preToggleBlocks = try Self.waitForStableOrderedList(fixturePath: TestFixtureHelper.fixturePath)

        // See the comment in testImagePasteMidListContinuesNumbering() above:
        // the label flips to "Source" before the WYSIWYG->CodeMirror view
        // swap necessarily finishes rendering, so this screenshot may still
        // show WYSIWYG. The proof below is the persisted `block` row, not pixels.
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear. Blocks before toggle: \(preToggleBlocks)")
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(
            editorMode.waitForLabel("== 'Source'", timeout: 10),
            "Editor-mode button should report Source (triggers the flush). Blocks before toggle: \(preToggleBlocks)"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "deliberate-new-list-after-toggle"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Same bounded stability poll in place of the old fixed
        // Thread.sleep(1.5): wait for the toggle-triggered flush (see file
        // header) to land and settle rather than assuming a fixed delay is
        // always long enough.
        let allBlocks = try Self.waitForStableOrderedList(fixturePath: TestFixtureHelper.fixturePath)

        let fragments = try Self.queryBlockMarkdownFragments(
            fixturePath: TestFixtureHelper.fixturePath,
            blockType: "ordered_list"
        )

        XCTAssertEqual(
            fragments.count, 1,
            "Expected exactly one ordered_list block (fixture starts with none). Got: \(fragments). All blocks: \(allBlocks)"
        )
        guard let onlyFragment = fragments.first else { return }

        let trimmed = onlyFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            trimmed.contains("Alpha item") && trimmed.contains("Beta item") && trimmed.contains("Gamma item"),
            "New list should contain all three items. Got: \(trimmed). All blocks: \(allBlocks)"
        )
        XCTAssertTrue(trimmed.hasPrefix("1."), "A deliberately-created new list must restart at 1. Got: \(trimmed). All blocks: \(allBlocks)")
    }

    // MARK: - Helpers

    /// Waits for the editor to be genuinely interactive (not just present in
    /// the AX tree -- the SwiftUI container can appear before Milkdown's JS
    /// bundle finishes loading), then moves the caret to the very end of the
    /// document.
    ///
    /// History of two failed approaches, both diagnosed with real runs (see
    /// `testZZDiagnosticDumpEditorAccessibilityTree`, since deleted):
    ///
    /// 1. Click `editor-area` (a large container group) immediately after
    ///    `waitForExistence`, then Cmd+A + rightArrow. This sometimes landed
    ///    typing INSIDE the fixture's "# Test Document" heading (fragmenting
    ///    it into things like "# 1. First item"), and once caused typing to
    ///    be silently dropped entirely (content came back byte-for-byte
    ///    unchanged from the fixture). Root cause: contrary to what was
    ///    assumed, the WebView already holds keyboard focus right after
    ///    launch (confirmed via `editorArea.debugDescription` showing
    ///    "Keyboard Focused" on the WebView/TextView nodes with no click at
    ///    all yet) -- clicking on the large container's default (center)
    ///    hit point was an unnecessary, occasionally-misdirected extra step.
    /// 2. Rely on Cmd+A + rightArrow alone (no click). Also inconsistent.
    ///
    /// This version instead clicks directly on a specific, known piece of
    /// REAL rendered text -- the fixture's last paragraph, "More content
    /// here." -- which the earlier diagnostic run showed IS exposed as its
    /// own `StaticText` accessibility element inside the WebView (Milkdown's
    /// WYSIWYG rendering is considerably more AX-visible than
    /// docs/guides/testing-architecture.md's blanket "cannot inspect
    /// internal state" claim suggests, at least for plain text nodes -- list
    /// numbering itself is a different matter, see the file header, which is
    /// why block-table verification is still used for the actual assertion).
    /// This guarantees a real click on real content (not a container's
    /// arbitrary center point). Clicking near the text's right edge (rather
    /// than its center, and with no follow-up `.end` keystroke -- see the
    /// method body for why) lands the caret at/near the end of that line
    /// directly, using only a real mouse event.
    private static func focusEditorAndGoToDocumentEnd(app: XCUIApplication, testCase: XCTestCase) {
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForExistence(timeout: 10), "Word count should appear in status bar")
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS is ready)")

        // Click near the RIGHT edge of the element's own frame (not its
        // center, and not followed by a `.end` keystroke -- a real run
        // showed a dropped/ignored `.end` leaves the caret wherever the
        // center-point click landed, splitting "More content here." into
        // "More con" / "tent here." and merging that tail into whatever got
        // typed next). A coordinate click is a real mouse event, not a
        // synthetic key event, so it isn't subject to the same drop risk.
        let lastParagraph = app.staticTexts["More content here."]
        XCTAssertTrue(lastParagraph.waitForExistence(timeout: 10), "Fixture's last paragraph should be visible and reachable via accessibility")
        let endOfLastParagraph = lastParagraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        endOfLastParagraph.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Puts a small solid-color PNG on the real system pasteboard, explicitly
    /// typed as `.png` so WKWebView's paste handler sees a `clipboardData`
    /// item whose type starts with "image/" (image-plugin.ts's handlePaste
    /// filter), regardless of what representation a bare NSImage would have
    /// registered on its own.
    private static func putTestImageOnPasteboard() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to build PNG test image for clipboard")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    /// Reads `markdownFragment` for every `block` row of the given `blockType`
    /// directly from the fixture's on-disk SQLite database, via the sqlite3
    /// CLI (present at /usr/bin/sqlite3 on macOS; the XCUITest runner process
    /// is unsandboxed, same as this project's existing Process()-based tests
    /// in final finalTests/Tier2/). Each fragment is terminated with a unique
    /// sentinel (rather than splitting on "\n") because markdownFragment
    /// itself routinely contains embedded newlines for multi-item lists.
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

    /// Diagnostic helper: dumps `id`, `sortOrder`, `blockType` + `markdownFragment`
    /// for every row, in document order, to distinguish "flush never ran" (zero
    /// rows), "flush ran but the list never formed" (rows exist, none are
    /// ordered_list), a duplicate write race (two rows with distinct `id`s --
    /// the app-level race filed as t-3904c457), and real fixture pollution (a
    /// row with content that was never typed in this test). `id` and
    /// `sortOrder` are included specifically so those cases can be told apart
    /// by a future failure, not just by re-running and guessing.
    private static func queryAllBlocks(fixturePath: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT id || ' | sortOrder=' || sortOrder || ' | ' || blockType || ': ' "
            + "|| markdownFragment || '\(sentinel)' FROM block ORDER BY sortOrder;"

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

    /// Quiesces the `block` table before `testDeliberateNewListRestartsAtOne`
    /// reads from it: polls (bounded at `timeout`, default 10s) until an
    /// `ordered_list` row exists AND the full block dump is byte-identical
    /// across two reads 1s apart, then returns that stable dump. Used both
    /// before the Cmd+/ mode toggle (to avoid racing the app's periodic
    /// Swift<->JS sync -- "500ms polling", per CLAUDE.md's core principle --
    /// while it's still catching up on the typing above) and, in place of the
    /// old fixed `Thread.sleep(1.5)`, before the final assertion read (to
    /// avoid racing the toggle-triggered flush described in the file header).
    ///
    /// This is a test-stabilization measure only: it does NOT paper over a
    /// genuine duplicate-write race (two distinct-`id` ordered_list rows that
    /// both stay present and identical across the 1s gap would still read as
    /// "stable" here) -- that would still be caught downstream by this test's
    /// `fragments.count == 1` assertion, whose failure message includes the
    /// full dump this helper returns. Fixing that race itself is out of scope
    /// -- see t-3904c457.
    ///
    /// If `timeout` elapses without an ordered_list row ever appearing, or
    /// without two consecutive reads matching, the last dump taken is
    /// returned anyway so the caller's own assertions -- not this helper --
    /// produce the failure, with real diagnostic content attached.
    private static func waitForStableOrderedList(fixturePath: String, timeout: TimeInterval = 10) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDump = try queryAllBlocks(fixturePath: fixturePath)

        while Date() < deadline {
            let hasOrderedList = lastDump.contains { $0.contains("ordered_list") }
            guard hasOrderedList else {
                Thread.sleep(forTimeInterval: 0.5)
                lastDump = try queryAllBlocks(fixturePath: fixturePath)
                continue
            }

            Thread.sleep(forTimeInterval: 1.0)
            let nextDump = try queryAllBlocks(fixturePath: fixturePath)
            if nextDump == lastDump {
                return nextDump
            }
            lastDump = nextDump
        }

        return lastDump
    }
}
