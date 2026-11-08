//
//  QuitFlushDuplicateInsertTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage -- reproduction test for TLA+ Finding #8
//  (Calm_InsertThenQuit, docs/architecture/tla/DocSyncCurrent.tla): a freshly typed paragraph must reach the
//  database exactly once when the user quits, never twice (once by the quit's whole-document write, once more by
//  the editor's own pending insert landing after it).
//
//  Phase 5 job B4: the 2-second block poll is gone. The editor reports each settled change itself, and the
//  lifecycle's save read holds the reports and covers every report it read (`registerSaveCover`), so a report of
//  the typed paragraph that reaches Swift after the whole-document write is dropped. Test 1 types and quits at
//  once (the report may still be on its way); test 3 drives the forced Notes rebuild the quit token defers. The
//  old test 2 (quit disarms the poll timer) went with the timer. The precise ordering case (a report posted before
//  the save read, arriving after it) is `ReportApplierTests.lifecycleFlushAndSaveCover`.
//

import XCTest
import WebKit
@testable import final_final

final class QuitFlushDuplicateInsertTests: XCTestCase {

    /// Distinctive marker text for the reproducing paragraph — never appears
    /// anywhere else in the fixture, so any row containing it must have come
    /// from either the quit-time flush's fresh parse or the paragraph's own
    /// report landing again after it.
    private static let marker = "zebra quokka marmot"

    private static let doc = """
    # Alpha

    one two three.
    """

    /// Keeps the WebView on-screen so requestAnimationFrame fires, and gives
    /// NSEvent-based typing a real key window to deliver into (mirrors
    /// CAYWConcurrentInsertTests.swift's makeHelper).
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Test 1: reproduction + regression

    /// Typing a new paragraph and quitting at once must write that paragraph to the database exactly once.
    @MainActor
    func testQuitFlush_typedParagraphReportInFlight_doesNotDuplicateParagraph() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, editorState) = (stack.helper, stack.db, stack.pid, stack.editorState)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        // Move the caret to the end of the heading (NOT the trailing paragraph -- see placeCursorAtEndOfHeading's doc
        // comment for why that anchor choice is load-bearing), press Return, and type a distinctive marker paragraph via
        // real NSEvents.
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)

        // Quit at once: only the 100 ms detection debounce is waited out, so the paragraph's report may still be on its
        // way (or not yet posted) when the save reads the editor.
        try await Task.sleep(nanoseconds: 150_000_000)
        let contentAfterType = try await helper.getContent()
        guard contentAfterType.contains(Self.marker) else {
            XCTFail("the typed paragraph never reached the editor; content=\(contentAfterType)")
            return
        }
        XCTAssertEqual(editorState.contentState, .idle, "precondition: the editor is idle")

        guard let quitToken = QuitFlushTestSupport.armQuit(editorState) else { return XCTFail("could not arm the quit token") }
        await QuitFlushTestSupport.flush(editorState, token: quitToken, webView: helper.webView)
        // Anything still on its way lands (or is dropped as covered) now.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        XCTAssertEqual(
            markerRows, 1,
            "Quit must write the new paragraph exactly once; found \(markerRows) rows containing '\(Self.marker)' "
                + "(2+ means the paragraph's report landed again after the quit's whole-document write)"
        )
    }

    // MARK: - Test 3: forced Notes rebuild (the OTHER trigger the quit's lifecycle token guards against)

    /// Reproduction + regression test for the fix's OTHER half: `flushForQuit()` ->
    /// `flushAllSync()` -> `flushPendingBibliographyAndFootnoteSync()` can force an
    /// already-scheduled, debounced Notes update to run immediately (the bibliography
    /// sibling needs a live Zotero connection -- see `performBibliographyUpdate`'s
    /// `zoteroService.isConnected` guard -- so this test drives the Notes/footnote path
    /// instead). That forced update writes to the database and posts
    /// `.notesSectionChanged`, which `ContentView.handleNotesSectionChanged()` handles
    /// by spawning its own untracked `Task` that calls
    /// `blockSyncService.pollBlockChangesNowForDatabaseRebuild()` with `force: true`,
    /// bypassing the contentState/generation guards entirely
    /// (`BlockSyncService.pollBlockChangesNow`'s own doc comment). Unsuppressed, that
    /// forced poll re-applies the still-pending, unconfirmed marker-paragraph insert a
    /// SECOND time on top of the row `flushAllSyncCore()`'s own full reparse already
    /// wrote moments earlier in the same `flushForQuit()` call.
    ///
    /// NO GATE/HOOK NEEDED HERE (unlike test 1's `QuitPollGate`): that test has to hold
    /// a poll cycle deterministically parked mid-flight because it races
    /// the sequence's drain (`raceDrain(bound:)`) against an *unforced* cycle that would otherwise skip
    /// unless caught at exactly the right moment. `force: true` here unconditionally
    /// bypasses those same guards, so once `handleNotesSectionChanged()`'s `Task` is
    /// spawned there is nothing left to synchronize against except that `Task`'s own
    /// ordinary completion, which the bounded poll loop below waits out (the same
    /// pattern `BibliographySectionFlagTests+DataIntegrity.swift`'s
    /// `handleBibliographySectionChangedSyncsSectionTableImmediately` uses for the
    /// sibling bibliography handler) -- not a real Timer, so the CFRunLoop-dependency
    /// hazard this file's header comment documents doesn't apply.
    ///
    /// `checkAndUpdateFootnotes`'s `footnoteRefs`/`fullContent` arguments are supplied
    /// directly here rather than derived from the live Milkdown document (in
    /// production they come from `onChange(of: editorState.content)`, a channel
    /// independent of block-sync's own pending-insert tracking, which the marker
    /// paragraph below still exercises for real via NSEvents) -- calling the trigger
    /// directly avoids the risk of typing a literal `[^1]` interacting with Milkdown's
    /// own footnote plugin, without weakening the test.
    @MainActor
    func testQuitFlush_forcedNotesRebuildPoll_doesNotDuplicateParagraph() async throws {
        let stack = try await makeContentViewStack()
        let (helper, db, pid, view) = (stack.helper, stack.db, stack.pid, stack.view)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid

        defer {
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
        }

        // Schedule a debounced Notes update -- simulates a footnote reference typed a
        // moment earlier, still sitting inside FootnoteSyncService's 3s debounce when
        // quit happens. Arming the quit token below SUSPENDS it (step 0: the debounce is
        // cancelled and the request recorded) -- since round C6 a quit no longer forces it
        // to run mid-quit; the test posts the rebuild notification itself instead.
        view.footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: ["1"], projectId: pid, fullContent: "# Alpha\n\n[^1]\n\none two three."
        )

        // Anchor to the heading, NOT the trailing paragraph -- see
        // placeCursorAtEndOfHeading's doc comment: an anchor on the paragraph would be
        // invalidated by flushContentToDatabase's own full reparse before the forced
        // rebuild poll ever ran, silently absorbing the race regardless of whether
        // the quit token's rebuild deferral works.
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)
        try await Task.sleep(nanoseconds: 600_000_000)

        let contentAfterType = try await helper.getContent()
        // Phase 5 B4: the page reports the paragraph itself (it is no longer held pending for a 2-second poll); whether its
        // report is still unacknowledged is logged, not required.
        let heldInOutbox = try await helper.webView.evaluateJavaScript(SwitchFlushTestSupport.outboxNotEmptyScript) as? Bool
        guard contentAfterType.contains(Self.marker) else {
            XCTFail(
                "the typed paragraph never became a pending, unconfirmed block-sync insert -- " +
                "heldInOutbox=\(String(describing: heldInOutbox)), " +
                "content contains marker=\(contentAfterType.contains(Self.marker)); " +
                "content=\(contentAfterType)"
            )
            return
        }

        // Wires the SAME NotificationCenter delivery SwiftUI's
        // `.onReceive(publisher(for: .notesSectionChanged))` provides in production --
        // `view` is never installed in a live view hierarchy here, so nothing delivers
        // this notification unless wired by hand (same reason the precedent
        // `handleBibliographySectionChangedSyncsSectionTableImmediately` calls its
        // handler directly instead). Delivered with `queue: nil` -- synchronous
        // delivery on the posting thread, matching production: the post happens from
        // `FootnoteSyncService.performFootnoteUpdate`, itself `@MainActor`, so this
        // closure runs on the main thread and `MainActor.assumeIsolated` is a true
        // isolation match, not a hop that would change the timing being tested.
        let observer = NotificationCenter.default.addObserver(
            forName: .notesSectionChanged, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                view.handleNotesSectionChanged()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The quit path: the quit token is armed FIRST (as `AppDelegate.runQuitSequence`
        // does), and the rebuild notification a debounce firing during the quit would
        // post arrives with the token armed -- the handler must DEFER it (set its pending
        // flag, spawn no Task, run no forced poll) instead of re-applying the
        // still-pending insert on top of the row the sequence writes. Then the sequence
        // runs: it drains and force-sends the editor, fetches fresh WebView content
        // (includes the typed marker) and writes it once through the ordered queue (1 row).
        guard let quitToken = QuitFlushTestSupport.armQuit(view.editorState) else { return XCTFail("could not arm the quit token") }
        NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
        XCTAssertTrue(
            view.editorState.pendingNotesRebuild,
            "the rebuild handler must defer (not run) while the quit token is armed")
        XCTAssertTrue(view.editorState.runningRebuildTasks.isEmpty, "a deferred handler starts no rebuild task")
        await QuitFlushTestSupport.flush(view.editorState, token: quitToken, webView: helper.webView)

        // Bounded poll (not a fixed sleep-and-hope): gives handleNotesSectionChanged()'s
        // fire-and-forget Task time to actually run its forced
        // pollBlockChangesNowForDatabaseRebuild() call and land (or not) a second row.
        var markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        let deadline = Date().addingTimeInterval(3)
        while markerRows == 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        }

        XCTAssertEqual(
            markerRows, 1,
            "Quit must write the footnote-triggering paragraph exactly once; found \(markerRows) " +
            "rows containing '\(Self.marker)' (2+ means handleNotesSectionChanged()'s forced " +
            "rebuild poll re-inserted the still-pending edit although the armed quit token should " +
            "have deferred the handler before it ever started its Task)"
        )
    }
}

// MARK: - Harness
//
// Split into an extension (rather than left inline in the class above) purely to keep
// the class body itself under SwiftLint's type_body_length limit -- extensions are
// excluded from that count by this project's .swiftlint.yml (`excluded_types:
// [extension, protocol]`). `private` members declared here remain visible to the class
// above because Swift shares `private` access across same-file extensions of a type; no
// behavior, logic, or access level changes as a result of this split.

extension QuitFlushDuplicateInsertTests {
    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
        let editorState: EditorViewState
    }

    @MainActor
    private func makeStack() async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on — without this,
        // sync stays paused forever and no edit ever registers (pure test artifact;
        // see ZoomWordCountSyncTests.swift's makeStack for the same shim).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)

        // Wire a real EditorViewState the way the app does (ContentView+ProjectLifecycle
        // .swift's configureSyncServices): editorState.blockSyncService for
        // flushForQuit()'s own calls, sync.editorState so the poll's block-change
        // application has one, and projectDatabase/currentProjectId so
        // flushAllSync()'s flushContentToDatabase() can actually write (see
        // SnapshotBackupFlushTests.swift for the same direct-assignment pattern).
        let editorState = EditorViewState()
        editorState.blockSyncService = sync
        sync.editorState = editorState
        editorState.projectDatabase = db
        editorState.currentProjectId = pid

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)
        editorState.content = content

        return EditorStack(helper: helper, db: db, pid: pid, sync: sync, editorState: editorState)
    }

    /// Number of blocks whose markdown contains `marker` — 1 is correct (the quit
    /// flush's own fresh parse); 2+ means a poll cycle re-inserted it.
    private func countRows(containing marker: String, db: ProjectDatabase, pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM block
                WHERE projectId = ? AND markdownFragment LIKE ?
                """, arguments: [pid, "%\(marker)%"]) ?? 0
        }
    }

    /// Collapses the native DOM selection to the end of the document's first
    /// heading ("# Alpha") — NOT the trailing paragraph ("one two three."),
    /// which a prior version of this test used (`placeCursorAtDocumentEnd`).
    ///
    /// WHY THE HEADING, NOT THE PARAGRAPH: anchoring the typed insert after the
    /// trailing PARAGRAPH made an earlier version of this test pass (1 row) even
    /// with `flushForQuit()`'s fix disabled — not because the fix was
    /// unnecessary, but because an entirely unrelated, pre-existing guard
    /// silently absorbed the race regardless. `flushForQuit()`'s own
    /// `flushAllSync()` → `flushContentToDatabase()` calls `replaceBlocks()`
    /// (EditorViewState+Zoom.swift), a FULL document re-parse that deletes every
    /// row and reinserts fresh ones, "preserving heading IDs and metadata by
    /// title match" but reassigning brand-new ids to every other block type (see
    /// that file's own `flushLiveContentToDatabase` doc comment: "flushContentTo
    /// Database()'s full re-parse reassigns fresh ids to most non-heading block
    /// types"). With the insert anchored to the paragraph, THAT anchor's id was
    /// always invalidated by this same flush before the parked poll cycle ever
    /// resumed — so `processEditorInserts`'s pre-existing stale-anchor guard
    /// (t-3904c457, `Database+BlocksInsert.swift`: "If the anchor resolves to
    /// nothing in the DB, this diff was computed against rows a structural
    /// rewrite ... has since replaced ... Reject it") silently `continue`d past
    /// the insert on every run, fix enabled or not — never reaching the
    /// (epoch, generation, chain) guards `flushForQuit()`'s fix actually
    /// targets. Anchoring to the HEADING instead survives `replaceBlocks()`'s
    /// reparse (its id is unchanged by title match), so the insert reaches
    /// those guards for real: with the fix disabled it now writes a genuine
    /// second row; with the fix restored, the drain cancels the parked cycle
    /// (via `Task.checkCancellation()` at the very top of `doPollBlockChanges`)
    /// before it ever gets that far.
    ///
    /// Real-world equivalent: "the user's cursor was on a blank line right
    /// after a heading when they hit Cmd+Q" — an ordinary place to type, not a
    /// contrived one. Confirmed against this same Milkdown editor by
    /// `HeadingParagraphExportOrderTests.swift`, which types a heading, presses
    /// a real Enter, and asserts the resulting block type is `"paragraph"` (not
    /// a second heading) — the same technique this helper relies on.
    @MainActor
    private func placeCursorAtEndOfHeading(_ helper: EditorTestHelper) async throws {
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const heading = pm.querySelector('h1');
                if (!heading) return 'no-heading';
                pm.focus();
                const range = document.createRange();
                range.selectNodeContents(heading);
                range.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to place cursor at end of heading (diagnostic: \(String(describing: result)))")
    }

    /// Real Return keypress (keyCode 36) via NSEvent — splits off a new paragraph.
    /// Same technique as CAYWConcurrentInsertTests.swift's pressEnter.
    @MainActor
    private func pressEnter(window: NSWindow) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ),
            let keyUp = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
        else {
            throw NSError(domain: "quit-flush-duplicate-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(keyUp)
    }

    /// Real keyDown/keyUp NSEvent pair per character — execCommand does not
    /// replicate real keyboard input in this app's editors (project rule; see
    /// CAYWConcurrentInsertTests.swift's typeViaNSEvents).
    @MainActor
    private func typeViaNSEvents(_ text: String, window: NSWindow) throws {
        for character in text {
            let charString = String(character)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                ),
                let keyUp = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                )
            else {
                throw NSError(
                    domain: "quit-flush-duplicate-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(keyUp)
        }
    }

    /// Harness for test 3: needs a real `ContentView` instance, not just a bare
    /// `EditorViewState`/`BlockSyncService` pair, because the mechanism under test --
    /// `ContentView.handleNotesSectionChanged()` -- lives on `ContentView`. A bare,
    /// never-rendered `ContentView()` with its services wired by hand (mirroring the
    /// private `configureSyncServices()` this file can't call directly) is sufficient,
    /// the same way `ProjectSwitchStaleContentPushTests.makeContentViewFixture` and
    /// `BibliographySectionFlagTests+DataIntegrity.swift`'s
    /// `handleBibliographySectionChangedSyncsSectionTableImmediately` already rely on:
    /// its unused `@Environment` properties are never read by the handler under test.
    private struct ContentViewStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let view: ContentView
    }

    @MainActor
    private func makeContentViewStack() async throws -> ContentViewStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Same rAF shim as makeStack() -- see that function's comment.
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let view = ContentView()
        // Mirrors ContentView+ProjectLifecycle.swift's private configureSyncServices():
        // the same BlockSyncService instance must back both flushForQuit()'s
        // drain/fetch calls and handleNotesSectionChanged()'s forced rebuild poll, so
        // the forced poll sees the pending insert flushForQuit() itself never consumed.
        view.blockSyncService.configure(database: db, projectId: pid, webView: helper.webView)
        view.editorState.blockSyncService = view.blockSyncService
        view.blockSyncService.editorState = view.editorState
        view.editorState.projectDatabase = db
        view.editorState.currentProjectId = pid
        view.footnoteSyncService.configure(database: db, projectId: pid)
        view.editorState.footnoteSyncService = view.footnoteSyncService

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await view.blockSyncService.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)
        view.editorState.content = content

        return ContentViewStack(helper: helper, db: db, pid: pid, view: view)
    }
}
