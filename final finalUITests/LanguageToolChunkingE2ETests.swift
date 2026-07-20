//
//  LanguageToolChunkingE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE end-to-end verification for the LanguageTool request-chunking fix
//  (oversized documents used to silently check nothing — see tasks.md's
//  "languagetool-proofreading" plan). Drives the REAL compiled app against
//  LanguageTool's real public API: no local/offline LT server exists in this
//  app today (see docs/deferred/self-hosted-languagetool.md), so there is no
//  way to prove "did chunking really run in the shipped app" without a real
//  network round trip.
//
//  What this test does NOT do: assert on which specific words/matches
//  LanguageTool's live server flags. That depends on live-server content this
//  test doesn't control and would make the test flaky for reasons that have
//  nothing to do with the fix being verified.
//
//  What this test DOES prove, via the `.proofing`-category DebugLog lines
//  LanguageToolProvider.buildChunks()/performChunkedNetworkCheck() emit
//  (forwarded to the persistent DiagnosticLogFile on disk, enabled here via a
//  launch-argument UserDefaults override — independent of the compile-time
//  DEBUG console category set):
//
//  1. The real app, given a real pasted document over the 18,000-char
//     request budget, actually decided to chunk (logged synchronously inside
//     buildChunks(), before any network request fires — no network wait
//     needed for this half of the proof).
//  2. The real app then dispatched more than one sequential real HTTP
//     request to LT's real endpoint as a result (the completion summary line
//     only appears after performChunkedNetworkCheck()'s request loop
//     finishes — one performNetworkCheck() call per chunk). This is true
//     even if every chunk's request fails (succeeded=false): the loop still
//     ran N times, each a genuine network attempt, which is what's being
//     verified here — not what LT's server returned.
//
//  Scaffolding, not a product test: delete once its evidence has been
//  captured. The chunking logic itself already has full mocked-network
//  unit/integration coverage (see LanguageToolProviderTests,
//  LanguageToolProviderDedupTests).
//

import XCTest
import AppKit

final class LanguageToolChunkingE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// One paragraph of natural-reading, deliberately-imperfect prose (not a
    /// precision fixture — this test never reads LT's actual matches, only
    /// whether chunking fired). ~657 chars long; repeated below to comfortably
    /// exceed LanguageToolProvider's 18,000-UTF-16-unit `maxRequestChars`.
    private static let paragraph = """
    Their are a few things that every writer should keep in mind when reviewing there own work, \
    even though its tempting to assume a sentence reads fine just because it sounds fine out loud. \
    Alot of subtle grammar mistakes hide in plain sight this way, especially when a paragraph is long \
    and the reader (or the writer, re-reading it) starts skimming instead of reading closely. Its \
    exactly this kind of realistic, natural-sounding prose that a proofreading tool needs to be tested \
    against, rather then a short list of obviously broken sentences that any checker would catch easily \
    regardless of how good it actually is at handling real, messy, human writing.

    """

    /// ~42,700 chars total (657 × 65) — well past the single-request budget,
    /// with enough headroom to reliably land on multiple chunks, similar in
    /// scale to the mocked 45,000-char/3-chunk integration test.
    private static let oversizedText = String(repeating: paragraph, count: 65)

    override func setUpWithError() throws {
        // Evaluate both assertions even if the first fails — this is a
        // disposable investigation test, and seeing both results (plus the
        // screenshot) is more useful for diagnosing a failure than stopping early.
        continueAfterFailure = true
        app = XCUIApplication.targetApp()
        app.terminate()

        try TestFixtureHelper.setupFixture(from: self)

        // Record where each candidate log file currently ends, so this test
        // only ever looks at bytes appended after this point — never deletes
        // or truncates the real, shared diagnostic log (which may hold many
        // days of real app-usage history on this machine).
        Self.recordDiagnosticLogStartOffsets()

        // Force LanguageTool Free (no API key needed) and turn on persistent
        // diagnostic logging, both via the NSUserDefaults launch-argument
        // domain — no Preferences-UI navigation required, and no dependency on
        // whatever mode/logging state a developer's real profile happens to have.
        app.launchArguments += [
            "-proofingMode", "languageToolFree",
            "-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"
        ]
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testLargeDocumentTriggersRealLanguageToolChunking() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")

        // Wait for the word-count status bar (the same readiness signal
        // EditorSmokeTests.testEditorOpensWithFixture uses) rather than just
        // "editor-area exists" — the SwiftUI container can appear before the
        // WKWebView's internal Milkdown/ProseMirror content is actually
        // initialized and focusable, which otherwise races a click+paste
        // attempted too early.
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Word count should appear before pasting")
        let initialWordCountValue = (wordCount.value as? String) ?? ""

        // Click into the upper portion of the editor panel (away from the thin
        // status bar at the bottom) to focus the WKWebView/editor first responder,
        // then re-confirm foreground focus immediately before the keyboard
        // shortcuts below, per this codebase's own activateAndWaitForForeground
        // convention for typeKey reliability.
        func focusAndPasteOversizedText() {
            editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
            app.activateAndWaitForForeground()
            app.typeKey("a", modifierFlags: .command)  // select all existing fixture content
            app.typeKey("v", modifierFlags: .command)  // replace with oversized text
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.oversizedText, forType: .string)

        focusAndPasteOversizedText()

        // Confirm the paste actually landed (word count changed from the tiny
        // fixture's original count) before waiting on the network-dependent
        // log lines below. A click-based WKWebView focus attempt can
        // occasionally race the editor's own JS init and silently no-op —
        // retry once if the first attempt doesn't seem to have landed.
        let escapedInitial = initialWordCountValue.replacingOccurrences(of: "'", with: "\\'")
        let pasteLanded = wordCount.waitForValue("!= '\(escapedInitial)'", timeout: 5)
        if !pasteLanded {
            focusAndPasteOversizedText()
            XCTAssertTrue(
                wordCount.waitForValue("!= '\(escapedInitial)'", timeout: 15),
                "Word count never changed after two paste attempts — the oversized text likely never reached the editor"
            )
        }

        // 1. Proof the app took the chunking code path.
        let triggerLine = Self.waitForDiagnosticLogLine(timeout: 20) { line in
            line.contains("[LT] chunking: consolidated text") && line.contains("exceeds 18000")
        }
        XCTAssertNotNil(
            triggerLine,
            "Expected the real app to log a chunking-trigger line for the oversized paste. " +
            "Diagnostic log contents:\n\(Self.currentDiagnosticLogContents())"
        )

        // 2. Proof multiple real sequential HTTP requests were actually
        // dispatched to LT's real endpoint. Generous timeout: up to a few real
        // network round trips (each individually capped at LanguageToolProvider's
        // own 10s per-request timeout), run sequentially, not concurrently.
        let completionLine = Self.waitForDiagnosticLogLine(timeout: 75) { line in
            line.contains("[LT] chunking:") && line.contains("chunks, merged")
        }
        XCTAssertNotNil(
            completionLine,
            "Expected the real app to complete a multi-chunk LanguageTool check. " +
            "Diagnostic log contents:\n\(Self.currentDiagnosticLogContents())"
        )

        if let completionLine, let chunkCount = Self.chunkCount(from: completionLine) {
            XCTAssertGreaterThan(
                chunkCount, 1,
                "Expected more than one chunk for a ~42,700-char document: \(completionLine)"
            )
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LanguageTool chunking — final proofing state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Diagnostic log helpers

    /// Mirrors DiagnosticLogFile.defaultLogDirectory's own path computation,
    /// but built WITHOUT going through any `$HOME`-resolving API.
    ///
    /// Confirmed by direct in-process instrumentation (2026-07-20 investigation
    /// run): the XCUITest *runner* process has its `HOME` environment variable
    /// itself overridden to the xctrunner's own container path — a
    /// test-isolation courtesy Xcode sets up, NOT a real App Sandbox — so
    /// EVERY Foundation API that resolves "the home directory"
    /// (`NSHomeDirectory()`, `NSHomeDirectoryForUser(NSUserName())`,
    /// `FileManager.default.homeDirectoryForCurrentUser`,
    /// `.urls(for: .applicationSupportDirectory, ...)`) returns that same
    /// wrong, container-relative path from this process, even though the real
    /// (unsandboxed) app process being tested writes its diagnostic log to
    /// the genuine `/Users/<user>/Library/Application Support/...` path.
    /// Direct instrumentation also confirmed `fileExists`/`isReadableFile` on
    /// the real, literal path both return true from this same process — i.e.
    /// this is purely an environment-variable-driven default, not an
    /// enforced sandbox that blocks reading outside `$HOME`. Building the
    /// path from `NSUserName()` (a plain POSIX call, unaffected by the `HOME`
    /// override) plus the standard `/Users/<name>` convention sidesteps the
    /// bad default entirely.
    private static func diagnosticLogCandidateURLs() -> [URL] {
        let relativePath = "Library/Application Support/com.kerim.final-final/Diagnostics"
        var directories: [URL] = []
        directories.append(
            URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent(relativePath, isDirectory: true)
        )
        // Fallbacks, kept for defense-in-depth in case the above ever differs
        // from where DiagnosticLogFile itself resolves at runtime.
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

    /// Byte offset, per candidate log file, recorded at test start — NOT
    /// deleted/truncated. This diagnostic log is real, shared, non-sandboxed
    /// user data (potentially many days of it, from real app usage on this
    /// machine); this test only ever reads bytes appended *after* its own
    /// start, and never removes or truncates anything that was already there.
    private static var logStartOffsets: [URL: UInt64] = [:]

    private static func recordDiagnosticLogStartOffsets() {
        logStartOffsets = [:]
        for url in diagnosticLogCandidateURLs() {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
                .flatMap { $0 }?.uint64Value ?? 0
            logStartOffsets[url] = size
        }
    }

    /// Only the portion of each candidate log file written after this test's
    /// own `recordDiagnosticLogStartOffsets()` call — i.e. only lines this
    /// test run itself could have produced.
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

    /// Polls the persistent diagnostic log on disk (written by the real,
    /// separately-running app process) until a line matching `predicate`
    /// appears, or `timeout` elapses. Returns the first matching line, if any.
    private static func waitForDiagnosticLogLine(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.5,
        _ predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let contents = currentDiagnosticLogContents()
            if let match = contents.split(separator: "\n").first(where: { predicate(String($0)) }) {
                return String(match)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return nil
    }

    /// Extracts the leading chunk count from a completion line of the form
    /// `"[LT] chunking: 3 chunks, merged 12 results, succeeded=true"`.
    private static func chunkCount(from line: String) -> Int? {
        guard let range = line.range(of: "chunking: ") else { return nil }
        let afterPrefix = line[range.upperBound...]
        let digits = afterPrefix.prefix(while: \.isNumber)
        return Int(digits)
    }
}
