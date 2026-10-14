//
//  CloseFlushDuplicateInsertTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — reproduction test for the close-time sibling of TLA+
//  Finding #8 (Calm_InsertThenQuit, docs/architecture/tla/DocSyncCurrent.tla):
//  `ContentView.performProjectClose(fetchContent:)` calls
//  `editorState.flushPendingBibliographyAndFootnoteSync(overrideContent:)` directly,
//  which can force an already-scheduled, debounced Notes update to run immediately.
//  That forced update writes to the database and posts `.notesSectionChanged`, which
//  `ContentView.handleNotesSectionChanged()` handles by spawning its own untracked
//  `Task` that calls `blockSyncService.pollBlockChangesNowForDatabaseRebuild()` --
//  a forced poll that bypasses the drain `stopPollingAndDrain()` already performed
//  and re-applies the still-pending, unconfirmed marker-paragraph insert a SECOND
//  time on top of the row `flushAllPendingContent`'s own full reparse already wrote
//  moments earlier in the same `performProjectClose` call.
//
//  `EditorViewState.suppressRebuildsForClose` (armed at the top of
//  `performProjectClose`, before `stopObserving()`) closes this gap by guarding both
//  `handleBibliographySectionChanged()` and `handleNotesSectionChanged()` -- mirroring
//  `suppressRebuildsForQuit`'s own guard in the same two handlers
//  (ContentView+NotificationHandlers.swift). See that property's doc comment
//  (EditorViewState.swift) for the full mechanism and why it is deliberately never
//  cleared.
//
//  This file is a SEPARATE file from QuitFlushDuplicateInsertTests.swift (not an
//  addition to it) because that file is already at 775 lines against SwiftLint's
//  800-line `file_length` warning -- it copies (rather than shares) that file's
//  private harness: `makeContentViewStack`, `placeCursorAtEndOfHeading`, `pressEnter`,
//  `typeViaNSEvents`, `countRows`, the `marker`/`doc` constants, and the `hostWindow`
//  setUp/tearDown. See that file's own header comment for why each harness piece is
//  shaped the way it is (real NSEvent typing, the heading anchor, the rAF shim, etc.)
//  -- none of that reasoning is repeated here.
//
//  This test only drives the Notes/footnote half of the fix. The bibliography half
//  needs a live Zotero connection (`performBibliographyUpdate`'s
//  `zoteroService.isConnected` guard) -- the same scope limit
//  QuitFlushDuplicateInsertTests.swift's test 3 already accepts for its own
//  bibliography sibling. The bibliography guard added next to the tested Notes guard
//  is otherwise identical in shape and is not independently exercised here.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop -- same
//  reasoning as QuitFlushDuplicateInsertTests.swift / ZoomWordCountSyncTests.swift.
//

import XCTest
import WebKit
@testable import final_final

final class CloseFlushDuplicateInsertTests: XCTestCase {

    /// Distinctive marker text for the reproducing paragraph — never appears
    /// anywhere else in the fixture, so any row containing it must have come from
    /// either the close-time flush's fresh parse or a later poll cycle re-applying
    /// the same still-pending insert.
    private static let marker = "zebra quokka marmot"

    private static let doc = """
    # Alpha

    one two three.
    """

    /// Keeps the WebView on-screen so requestAnimationFrame fires, and gives
    /// NSEvent-based typing a real key window to deliver into (mirrors
    /// QuitFlushDuplicateInsertTests.swift's hostWindow).
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Reproduction + regression: forced Notes rebuild poll during close

    /// Reproduction + regression test for `EditorViewState.suppressRebuildsForClose`:
    /// typing a new, footnote-triggering paragraph, then closing the project while a
    /// debounced Notes update is still pending, must write that paragraph to the
    /// database exactly once — never twice.
    ///
    /// NO GATE/HOOK NEEDED HERE (unlike a periodic-poll-drain race test): the forced
    /// rebuild poll `handleNotesSectionChanged()` spawns bypasses the contentState/
    /// generation guards unconditionally (`force: true`), so once that handler's
    /// `Task` is spawned there is nothing left to synchronize against except its own
    /// ordinary completion, which the bounded poll loop below waits out -- same
    /// pattern as QuitFlushDuplicateInsertTests.swift's own test 3.
    @MainActor
    func testCloseFlush_forcedNotesRebuildPoll_doesNotDuplicateParagraph() async throws {
        let stack = try await makeContentViewStack()
        let (helper, db, pid, view) = (stack.helper, stack.db, stack.pid, stack.view)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        // Production order (FileOperations.handleCloseProject(), FileCommands.swift):
        // dm.closeProject() runs BEFORE .projectDidClose is posted, so
        // performProjectClose always runs with DocumentManager's own project state
        // already nil'd out -- mirror that here rather than leaving it pointed at
        // this test's fixture.
        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.projectDatabase = nil
        DocumentManager.shared.projectId = nil
        defer {
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
            view.blockSyncService.stopPolling()
        }

        // Schedule a debounced Notes update -- simulates a footnote reference typed a
        // moment earlier, still sitting inside FootnoteSyncService's 3s debounce when
        // close happens. performProjectClose()'s flushPendingBibliographyAndFootnoteSync
        // below forces it to run NOW instead of waiting out that debounce.
        view.footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: ["1"], projectId: pid, fullContent: "# Alpha\n\n[^1]\n\none two three."
        )

        // Anchor to the heading, NOT the trailing paragraph -- see
        // QuitFlushDuplicateInsertTests.placeCursorAtEndOfHeading's doc comment for why
        // that anchor choice is load-bearing.
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)
        try await Task.sleep(nanoseconds: 600_000_000)

        let contentAfterType = try await helper.getContent()
        let hasPending = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        guard hasPending == true, contentAfterType.contains(Self.marker) else {
            XCTFail(
                "the typed paragraph never became a pending, unconfirmed block-sync insert -- " +
                "hasBlockChanges()=\(String(describing: hasPending)), " +
                "content contains marker=\(contentAfterType.contains(Self.marker)); " +
                "content=\(contentAfterType)"
            )
            return
        }

        // Wires the SAME NotificationCenter delivery SwiftUI's
        // `.onReceive(publisher(for: .notesSectionChanged))` provides in production --
        // `view` is never installed in a live view hierarchy here, so nothing delivers
        // this notification unless wired by hand (same reason
        // QuitFlushDuplicateInsertTests.swift's test 3 does the same). `notesPosts`
        // guards against a vacuous pass: if the forced flush never actually posts,
        // finding 1 row afterward would prove nothing about suppression.
        //
        // `handlerGuardsWerePassable` is a second, narrower vacuity check (review round 1,
        // must-fix #2): `notesPosts >= 1` only proves the notification was posted, not that
        // `handleNotesSectionChanged()` actually reached the new `suppressRebuildsForClose`
        // guard rather than returning earlier on one of its OTHER, unrelated guards (zoomed,
        // `contentState != .idle`, or empty `editorState.content` -- see that function's own
        // early returns, ContentView+NotificationHandlers.swift). Recorded INSIDE the
        // observer, before calling the handler, so it reflects the exact state the handler
        // itself would have seen. True today; if a later close-order change makes one of
        // these other guards fire first, this assertion (not just the marker-row count) is
        // what catches this test having silently stopped exercising the guard under test.
        var notesPosts = 0
        var handlerGuardsWerePassable = true
        let observer = NotificationCenter.default.addObserver(
            forName: .notesSectionChanged, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notesPosts += 1
                let trimmedContent = view.editorState.content.trimmingCharacters(in: .whitespacesAndNewlines)
                handlerGuardsWerePassable = handlerGuardsWerePassable
                    && view.editorState.contentState == .idle
                    && !trimmedContent.isEmpty
                    && view.editorState.zoomedSectionId == nil
                view.handleNotesSectionChanged()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The real close path: arms suppressRebuildsForClose, drains (a no-op here --
        // no poll was ever started in this test), fetches fresh WebView content
        // (includes the typed marker), then flushAllPendingContent writes the marker
        // via a full reparse (1 row) before flushPendingBibliographyAndFootnoteSync
        // forces the footnote update scheduled above to run now -- which posts
        // .notesSectionChanged synchronously from inside this same call stack, exactly
        // as production's debounce-fire path would.
        await view.performProjectClose(fetchContent: { try? await helper.getContent() })

        // Bounded poll (not a fixed sleep-and-hope): gives handleNotesSectionChanged()'s
        // fire-and-forget Task time to actually run its forced
        // pollBlockChangesNowForDatabaseRebuild() call and land (or not) a second row.
        var markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        let deadline = Date().addingTimeInterval(3)
        while markerRows == 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        }

        XCTAssertGreaterThanOrEqual(
            notesPosts, 1,
            "forced footnote flush never posted .notesSectionChanged -- test would pass vacuously"
        )
        XCTAssertTrue(
            handlerGuardsWerePassable,
            "handleNotesSectionChanged()'s own earlier guards (contentState == .idle, non-empty " +
            "content, not zoomed) were already false when .notesSectionChanged posted -- this test " +
            "would then be proving one of those guards, not suppressRebuildsForClose"
        )
        XCTAssertEqual(
            markerRows, 1,
            "Close must write the footnote-triggering paragraph exactly once; found \(markerRows) " +
            "rows containing '\(Self.marker)' (2+ means handleNotesSectionChanged()'s forced " +
            "rebuild poll re-inserted the still-pending edit after suppressRebuildsForClose should " +
            "have blocked the handler from ever starting its Task)"
        )
    }
}

// MARK: - Harness
//
// Copied (not shared) from QuitFlushDuplicateInsertTests.swift -- see this file's own
// header comment for why. Split into an extension purely to keep the class body
// itself under SwiftLint's type_body_length limit, matching that file's own layout;
// `private` members declared here remain visible to the class above because Swift
// shares `private` access across same-file extensions of a type.

extension CloseFlushDuplicateInsertTests {
    /// Number of blocks whose markdown contains `marker` — 1 is correct (the close
    /// flush's own fresh parse); 2+ means a poll cycle re-inserted it.
    private func countRows(containing marker: String, db: ProjectDatabase, pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM block
                WHERE projectId = ? AND markdownFragment LIKE ?
                """, arguments: [pid, "%\(marker)%"]) ?? 0
        }
    }

    /// Collapses the native DOM selection to the end of the document's first heading
    /// ("# Alpha") — NOT the trailing paragraph ("one two three."). See
    /// QuitFlushDuplicateInsertTests.placeCursorAtEndOfHeading's own doc comment for
    /// why anchoring to the heading (which survives the close flush's full re-parse)
    /// rather than the paragraph (whose id that re-parse invalidates) is load-bearing.
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
    /// Same technique as QuitFlushDuplicateInsertTests.swift's pressEnter.
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
            throw NSError(domain: "close-flush-duplicate-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(keyUp)
    }

    /// Real keyDown/keyUp NSEvent pair per character — execCommand does not replicate
    /// real keyboard input in this app's editors (project rule; see
    /// QuitFlushDuplicateInsertTests.swift's typeViaNSEvents).
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
                    domain: "close-flush-duplicate-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(keyUp)
        }
    }

    /// Harness for a real `ContentView` instance, not just a bare `EditorViewState`/
    /// `BlockSyncService` pair, because the mechanism under test --
    /// `ContentView.handleNotesSectionChanged()` AND `performProjectClose()` -- both
    /// live on `ContentView`. A bare, never-rendered `ContentView()` with its services
    /// wired by hand (mirroring the private `configureSyncServices()` this file can't
    /// call directly) is sufficient -- same pattern
    /// QuitFlushDuplicateInsertTests.makeContentViewStack uses.
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

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on — without this,
        // sync stays paused forever and no edit ever registers (pure test artifact;
        // see QuitFlushDuplicateInsertTests.swift's makeStack for the same shim).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let view = ContentView()
        // Mirrors ContentView+ProjectLifecycle.swift's private configureSyncServices():
        // the same BlockSyncService instance must back both performProjectClose()'s
        // drain/fetch calls and handleNotesSectionChanged()'s forced rebuild poll, so
        // the forced poll sees the pending insert performProjectClose() itself never
        // consumed.
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
