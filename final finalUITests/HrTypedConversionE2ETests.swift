//
//  HrTypedConversionE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the hr/horizontal_rule block-sync fix.
//
//  Code review found the first version of this fix only handled the INSERT
//  path (pasting/importing a new hr node). The dominant real-world scenario —
//  a user typing "---" character-by-character into an EXISTING, already-synced
//  paragraph — converts that paragraph in place (ProseMirror keeps its block
//  id, since neither paragraph nor hr is an atomic type), so it reaches Swift
//  as a BlockUpdate, not a BlockInsert. The fix round added a thematic-break
//  branch to Database+Blocks.swift's update-handling chain to cover this.
//
//  This test proves the real, character-by-character typing path end-to-end:
//  create a fresh paragraph live, let it flush and confirm as a real DB row
//  (matching the real async debounce/poll timing that a synthetic single-shot
//  test would collapse away), THEN type "-", "-", "-" as separate keystrokes
//  into that existing row, wait for the real debounce + poll cycle again, and
//  verify via direct DB read that the row now has blockType='horizontal_rule'
//  — then relaunch and confirm it visually re-renders as a rule, not stranded
//  text.
//
//  Delete this file once its evidence has been captured — it is disposable
//  verification scaffolding, not a permanent regression test.
//

import XCTest

final class HrTypedConversionE2ETests: XCTestCase {
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

    func testTypedHorizontalRulePersistsAcrossReload() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")

        Thread.sleep(forTimeInterval: 1.5)

        // Click at the very end of the document to place the caret after all
        // existing content, then create a brand-new empty paragraph.
        app.activateAndWaitForForeground()
        app.typeKey(.downArrow, modifierFlags: .command) // jump to end of document
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        // Let this new empty paragraph flush and get a REAL, confirmed block
        // id before we touch it again — this is exactly the async gap the
        // review found: converting a block before its own insert has been
        // confirmed produces different behavior than converting an
        // already-settled block. Same debounce+poll wait NestedListE2ETests
        // uses for this codebase's real timing (~100ms JS debounce + 2s Swift
        // poll, generous margin).
        Thread.sleep(forTimeInterval: 4.0)

        let beforeBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[HrTypedConversionE2ETests] DIAGNOSTIC blocks before typing dashes:\n\(beforeBlocks.joined(separator: "\n---\n"))")

        // Now type the three dashes as SEPARATE keystrokes (not one string a
        // synthetic test would fire atomically) into that now-existing,
        // already-synced empty paragraph — the real "press Enter, type ---"
        // sequence a user performs.
        app.typeText("-")
        Thread.sleep(forTimeInterval: 0.05)
        app.typeText("-")
        Thread.sleep(forTimeInterval: 0.05)
        app.typeText("-")

        let afterTypeAttachment = XCTAttachment(screenshot: app.screenshot())
        afterTypeAttachment.name = "after-typing-dashes"
        afterTypeAttachment.lifetime = .keepAlways
        add(afterTypeAttachment)

        // Wait for the real debounce + poll cycle to persist the conversion.
        Thread.sleep(forTimeInterval: 4.0)

        let afterBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[HrTypedConversionE2ETests] DIAGNOSTIC blocks after typing dashes:\n\(afterBlocks.joined(separator: "\n---\n"))")

        let hrFragments = try Self.queryBlockMarkdownFragments(fixturePath: TestFixtureHelper.fixturePath, blockType: "horizontal_rule")
        XCTAssertEqual(
            hrFragments.count, 1,
            "BUG: typing '---' into an existing paragraph should produce exactly one horizontal_rule row. Got \(hrFragments.count). All blocks: \(afterBlocks)"
        )

        let staleParagraphs = try Self.queryBlockMarkdownFragments(fixturePath: TestFixtureHelper.fixturePath, blockType: "paragraph")
        XCTAssertFalse(
            staleParagraphs.contains("---"),
            "BUG: a stale paragraph row still holds the literal '---' text — the row was not converted, only a duplicate hr was inserted. All blocks: \(afterBlocks)"
        )

        // Relaunch against the same mutated fixture and confirm the rule
        // re-renders visually, not as stranded "---" text.
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorAreaAfterReopen = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterReopen.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")
        Thread.sleep(forTimeInterval: 1.5)

        let strandedDashText = app.staticTexts["---"]
        XCTAssertFalse(strandedDashText.exists, "The literal text '---' should NOT appear as plain text after reload — it should have rendered as a rule")

        let postReopenAttachment = XCTAttachment(screenshot: app.screenshot())
        postReopenAttachment.name = "after-reopen"
        postReopenAttachment.lifetime = .keepAlways
        add(postReopenAttachment)
    }

    // MARK: - DB query helpers (copied verbatim from NestedListE2ETests.swift)

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
