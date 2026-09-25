//
//  WebKitStorageClearE2ETests.swift
//  final finalUITests
//
//  E2E test for the ui-test-webkit-storage-clear task: verifies that the
//  WKWebsiteDataStore.removeData() wipe in AppDelegate.applicationWillFinishLaunching
//  actually clears the citation-cache localStorage entry before the next UI-test launch
//  reads it back. See the class doc comment below for how the test proves this.
//

import XCTest

/// ui-test-webkit-storage-clear task: proves the `WKWebsiteDataStore.removeData()` wipe in
/// `AppDelegate.applicationWillFinishLaunching` actually empties the citation-cache localStorage
/// entry (`ff-citation-library`, citation-search.ts) before the NEXT UI-test launch's editor
/// reads it back — not merely that the code compiles and the unit suite passes.
///
/// **Launch 1** (`FF_UI_TESTING_ZOTERO_MOCK=1`): inserts a canned citation via the CAYW mock
/// picker (Cmd-Shift-K — established pattern, see
/// `UnifiedUndoE2ETests.testCitationInsertRacedAgainstStructuralOpIsCancelledNotCorrupted`),
/// which drives `cayw.ts`'s `handleCAYWCallback` -> citation-search.ts's `setCitationLibrary()`
/// -> a `localStorage.setItem` write into `WKWebsiteDataStore.default()`. Polls fixture A's
/// `content.sqlite` for the mock citekey to confirm the insert actually landed — the positive
/// control proving the cache write really happened, not just that the picker fired. Then quits
/// the app for real (`app.terminate()`, not just backgrounding it) so the disk-backed store has
/// a chance to flush before launch 2 starts.
///
/// **Launch 2** (`FF_UI_TESTING=1` only, no mock, a FRESH never-opened project/fixture): reads
/// the persistent diagnostic log (`DebugLog` -> `DiagnosticLogFile`, turned on here via the
/// `-com.kerim.final-final.diagnosticsLoggingEnabled YES` launch argument — established pattern,
/// `UnifiedUndoE2ETests+Helpers.swift`) for two lines:
///   (a) `"[AppDelegate] UI test mode: cleared WKWebsiteDataStore (all data types)"` — already
///       existed; confirms the `removeData()` completion handler actually fired this launch.
///   (b) `"[MilkdownEditor] citation cache size at editor-ready:"` — the hook this task added
///       (`logCitationCacheSizeForUITesting`, `MilkdownCoordinator+MessageHandlers.swift`),
///       fired only once `notifyWebViewReadyWhenEditorReady` confirms `isEditorReady()`, which
///       is guaranteed to be AFTER `restoreCitationLibrary()` has already run (main.ts sets
///       `isEditorReady()`'s backing flag only after that restore, never before). A trailing "0"
///       is the direct proof the localStorage cache came back empty on this fresh launch, not
///       carried over from launch 1's mock citation.
///
/// The diagnostic-log read offset is captured right before launch 2 starts, so every line read
/// back belongs to launch 2 alone — (a) appearing before (b) in that captured text is itself the
/// ordering proof this task asked for, since this app's diagnostic log is a strictly append-only,
/// single-writer-per-process file (`DiagnosticLogFile.append`, `FileHandle.write(contentsOf:)`
/// straight to the `write(2)` syscall).
final class WebKitStorageClearE2ETests: XCTestCase {
    var app: XCUIApplication!
    private var fixtureBPath: String?

    /// Must match `ZoteroService+CAYW.swift`'s `mockCitekey` — same established value
    /// `UnifiedUndoE2ETests` uses.
    private let mockCitekey = "ffe2emockcitation2026"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        // Diagnostics logging on for every launch in this test -- established convention, see
        // UnifiedUndoE2ETests+Helpers.swift's launchAndWaitForEditor(). This is an NSArgumentDomain
        // override, so it survives both AppDelegate's UI-test UserDefaults wipe AND
        // AppDefaults.wipeTestDomainForUITesting() (neither touches the argument domain), and it
        // applies to every `launch()` call made on this same XCUIApplication instance, including
        // launch 2 below.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        if let fixtureBPath {
            try? FileManager.default.removeItem(atPath: fixtureBPath)
        }
    }

    func testWebKitStorageClearedBeforeCitationCacheReadOnNextLaunch() throws {
        let fixtureAPath = TestFixtureHelper.fixturePath

        // --- Launch 1: populate the citation cache via a mock CAYW insert -------------------
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        // Captured before the app even launches, so the diagnostic-log wait below (for the
        // editor-ready gate) reads only bytes this launch itself appends -- same offset-based
        // pattern launch 2 already uses just before ITS launch, see recordDiagnosticLogStartOffsets's
        // doc comment.
        Self.recordDiagnosticLogStartOffsets()
        app.launchForTesting(fixturePath: fixtureAPath)

        let editorArea1 = app.editorArea
        XCTAssertTrue(editorArea1.waitForExistence(timeout: 10), "Editor area should appear for launch 1")
        let wordCount1 = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(
            wordCount1.waitForValue("CONTAINS 'words'", timeout: 10),
            "Launch 1 status-bar word-count label should render -- NOT proof the editor itself is " +
            "ready (see the comment below on why this label can't be used as a readiness gate)"
        )

        // Root cause of this test's repeated positive-control failure (diagnosed by
        // superdev-diagnostician; supersedes an earlier, WRONG "click re-asserting foreground
        // disturbs focus" theory that used to live here): the word-count wait above never gated on
        // editor readiness at all. `status-bar-word-count` reads "0 words" on the very first frame,
        // before the WKWebView's editor exists, so that wait was passing instantly on every run,
        // regardless of click/activate ordering. The Cmd-Shift-K keystroke then fired before the
        // editor was actually ready. It reaches `MilkdownCoordinator.executeFormatting
        // ("insertCitation")`, which starts with `guard isEditorReady, let webView else { return }` --
        // so the command was silently dropped every time.
        //
        // The fix: wait for real editor readiness before sending the keystroke, two ways --
        // (1) fixture A's seeded paragraph actually rendering (`editorStaticText(startingWith:)`,
        // the same idiom `BibRebuildErasesEditE2ETests`/`RebuildFlushTypingRaceE2ETests` already use
        // for their own first-insert-after-launch sequences), and (2) the diagnostic log itself
        // showing `notifyWebViewReadyWhenEditorReady`'s "editor-ready gate satisfied" line
        // (`MilkdownCoordinator+MessageHandlers.swift`) -- a stricter signal than (1) alone, since it
        // comes straight from the gate `executeFormatting`'s own `isEditorReady` guard depends on.
        guard let paragraph = app.editorStaticText(startingWith: "This is a test paragraph", timeout: 10) else {
            XCTFail("Fixture A's paragraph never rendered in the editor.\n\(app.editorStaticTextsDump())")
            return
        }
        let readyLog = Self.waitForDiagnosticLog(containingAll: ["editor-ready gate satisfied"], timeout: 15)
        XCTAssertTrue(
            readyLog.contains("editor-ready gate satisfied"),
            "Launch 1's diagnostic log should show the editor-ready gate firing before the citation " +
            "insert -- log:\n\(readyLog)"
        )
        app.activateAndWaitForForeground()
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        app.typeKey("k", modifierFlags: [.command, .shift])

        let contentAfterInsert = waitForFixtureMarkdown(fixturePath: fixtureAPath, containing: mockCitekey, timeout: 13.0)
        XCTAssertTrue(
            contentAfterInsert.contains(mockCitekey),
            "Mock citation insert (Cmd-Shift-K) should land in fixture A's document -- this is the " +
            "positive control proving citation-search.ts's setCitationLibrary() actually persisted " +
            "something to localStorage before quitting; citekey \"\(mockCitekey)\" not found"
        )

        // Quit for real (not just background) so WKWebsiteDataStore's disk-backed localStorage
        // has a chance to flush before launch 2 starts.
        app.terminate()

        // --- Launch 2: fresh project, no mock -------------------------------------------------
        // Everything the diagnostic-log reader returns from this point on belongs to launch 2
        // alone.
        Self.recordDiagnosticLogStartOffsets()

        let fm = FileManager.default
        let bPath = NSTemporaryDirectory() + "ff-test-fixture-B-\(UUID().uuidString).ff"
        let bundle = Bundle(for: type(of: self))
        guard let fixtureSource = bundle.resourceURL?.appendingPathComponent("Fixtures/test-fixture.ff"),
              fm.fileExists(atPath: fixtureSource.path) else {
            XCTFail("Test fixture not found in UI test bundle")
            return
        }
        try? fm.removeItem(atPath: bPath)
        try fm.copyItem(at: fixtureSource, to: URL(fileURLWithPath: bPath))
        fixtureBPath = bPath

        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = nil // no mock this launch, per the task's brief
        app.launchForTesting(fixturePath: bPath)

        let editorArea2 = app.editorArea
        XCTAssertTrue(editorArea2.waitForExistence(timeout: 10), "Editor area should appear for launch 2")
        let wordCount2 = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(
            wordCount2.waitForValue("CONTAINS 'words'", timeout: 10),
            "Launch 2 status-bar word-count label should render -- NOT proof the editor itself is " +
            "ready; the diagnostic-log poll just below is what actually confirms editor-ready state"
        )

        // This poll -- waiting up to 10s for both diagnostic-log lines to actually land on
        // disk -- IS the real readiness gate here, unlike the word-count check above, which
        // (per this task's diagnosis, see the comment on launch 1) proves nothing about editor
        // readiness by itself.
        let logText = Self.waitForDiagnosticLog(
            containingAll: ["cleared WKWebsiteDataStore", "citation cache size at editor-ready"],
            timeout: 10
        )
        XCTContext.runActivity(named: "Launch 2 diagnostic log evidence") { $0.add(XCTAttachment(string: logText)) }

        let clearRange = logText.range(of: "cleared WKWebsiteDataStore")
        let cacheSizeRange = logText.range(of: "citation cache size at editor-ready")
        XCTAssertNotNil(clearRange, "Launch 2's diagnostic log should show the WKWebsiteDataStore clear completing -- log:\n\(logText)")
        XCTAssertNotNil(cacheSizeRange, "Launch 2's diagnostic log should show the citation-cache-size hook firing -- log:\n\(logText)")

        if let clearRange, let cacheSizeRange {
            XCTAssertTrue(
                clearRange.lowerBound < cacheSizeRange.lowerBound,
                "The WKWebsiteDataStore clear must complete BEFORE the citation cache is read at " +
                "editor-ready -- log:\n\(logText)"
            )
        }

        XCTAssertTrue(
            logText.contains("citation cache size at editor-ready: 0"),
            "Launch 2 (fresh project, no mock) should read the citation cache back EMPTY -- the " +
            "WebKit storage clear should have removed launch 1's mock citation before this read. " +
            "Log:\n\(logText)"
        )
    }

    // MARK: - Fixture polling (mirrors UnifiedUndoE2ETests+Helpers.swift's queryAllMarkdownConcatenated,
    // parameterized by fixture path since this test uses two independent fixtures)

    private func waitForFixtureMarkdown(fixturePath: String, containing needle: String, timeout: TimeInterval) -> String {
        let sql = "SELECT COALESCE((SELECT markdown FROM content), '') || char(10) || " +
            "COALESCE((SELECT group_concat(markdownContent, char(10)) FROM section), '');"
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = ""
        repeat {
            last = FixtureDatabase.read(fixturePath: fixturePath, sql: sql)
            if last.contains(needle) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return last
    }

    // MARK: - Diagnostic log reading (same proven, offset-based pattern as
    // UnifiedUndoE2ETests+Helpers.swift / E2ESectionReconcilerPseudoSectionTests.swift --
    // reads only bytes appended since the last checkpoint, never truncates/deletes the real,
    // shared log)

    private static var diagnosticLogStartOffsets: [URL: UInt64] = [:]

    /// Three directory candidates x 3 rotation filenames, deduped by resolved path -- see
    /// UnifiedUndoE2ETests+Helpers.swift's own copy of this helper for why the dedup matters
    /// (the "tripling bug", 2026-08-31).
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
        let allCandidates = directories.flatMap { dir in fileNames.map { dir.appendingPathComponent($0) } }

        var seenResolvedPaths = Set<String>()
        var deduped: [URL] = []
        for url in allCandidates {
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seenResolvedPaths.insert(resolvedPath).inserted {
                deduped.append(url)
            }
        }
        return deduped
    }

    private static func recordDiagnosticLogStartOffsets() {
        diagnosticLogStartOffsets = [:]
        for url in diagnosticLogCandidateURLs() {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
                .flatMap { $0 }?.uint64Value ?? 0
            diagnosticLogStartOffsets[url] = size
        }
    }

    private static func currentDiagnosticLogContents() -> String {
        diagnosticLogCandidateURLs().compactMap { url -> String? in
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: diagnosticLogStartOffsets[url] ?? 0)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n---\n")
    }

    private static func waitForDiagnosticLog(containingAll needles: [String], timeout: TimeInterval) -> String {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = ""
        repeat {
            last = currentDiagnosticLogContents()
            if needles.allSatisfy({ last.contains($0) }) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return last
    }
}
