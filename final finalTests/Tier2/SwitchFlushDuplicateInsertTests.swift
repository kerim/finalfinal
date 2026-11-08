//
//  SwitchFlushDuplicateInsertTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md section 7.2 "C7a", plan-v3 U4, coder obligation 33):
//  the project-SWITCH sibling of `QuitFlushDuplicateInsertTests` / `CloseFlushDuplicateInsertTests`, the
//  duplicate-paragraph shape of TLA+ Finding #8 (t-e3ec2e7b's mechanism).
//
//  The setup: a typed paragraph is a pending, unconfirmed block-sync insert, and a Notes rebuild
//  (`ContentView.handleNotesSectionChanged()`) is RUNNING when the user opens another project. That rebuild's first
//  step is `pollBlockChangesNowForDatabaseRebuild()`, a FORCED poll that applies the pending insert. If the
//  switch's own save then ran first, or if the rebuild's poll ran again after the whole-document save, the
//  paragraph would be written twice (two rows).
//
//  What this test PINS (item 33 asks every such test to name its mechanism, and the DEBUG line at the end of the
//  test says so): the END STATE. FB, the queued whole-document write, replaces the block table with the editor's
//  content, which holds the paragraph once, and the epoch stamp it bumps (slice-3a-1a.md (D)) makes the writer refuse
//  any editor batch fetched before it, so the pending insert cannot be applied a second time afterwards: exactly one
//  marker row. It also asserts that the rebuild was running at arm and no longer runs once the sequence returns, but
//  that is not the proof of step 3's ORDER.
//
//  What this test does NOT prove: that step 3 awaits a running rebuild BEFORE F. That order is proven by
//  `LifecycleFlushGuardTests.runningRebuild_isAwaited_andLandsBeforeF` (Tier2), which records the rebuild's push and
//  F's first poll in one log and compares their positions. This test would not necessarily fail with step 3's wait
//  removed, because FB plus the epoch stamp already prevent the duplicate row on their own. The plan's other
//  candidate, a "post-poll abort check" (abandon the switch if a rebuild's poll lands during it), is deliberately NOT
//  built (round C4: it conflicts with awaiting the rebuild to completion), so it is not what protects the database.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop -- same reasoning as
//  QuitFlushDuplicateInsertTests.swift / CloseFlushDuplicateInsertTests.swift, whose harness this copies.
//

import XCTest
import WebKit
@testable import final_final

final class SwitchFlushDuplicateInsertTests: XCTestCase {

    /// Distinctive marker text: any row containing it came from the fresh write or a poll re-applying the insert.
    private static let marker = "gnu pangolin ibex"

    private static let doc = """
    # Alpha

    one two three.
    """

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    @MainActor
    func testSwitchFlush_runningNotesRebuild_isAwaitedAndDoesNotDuplicateParagraph() async throws {
        let stack = try await makeContentViewStack()
        let (helper, db, pid, view) = (stack.helper, stack.db, stack.pid, stack.view)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        // `fetchBlocksWithIds()` (the rebuild's second step) reads the open project from `DocumentManager`.
        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid
        defer {
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
        }

        // Anchor to the heading, NOT the trailing paragraph (see QuitFlushDuplicateInsertTests.placeCursorAtEndOfHeading).
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)

        // Wait (bounded) for the typed paragraph to show in the editor AND be held as a pending, unconfirmed block-sync
        // insert, rather than sleeping a fixed time and probing once. Read-only: nothing here consumes the pending insert.
        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper) { $0.contains(Self.marker) }
        XCTAssertTrue(observed.contentMatches, "the typed marker never reached the editor; content=\(observed.content)")
        guard observed.isReady else { return }

        // A Notes rebuild is RUNNING when the switch begins: the handler spawns its Task, which first forces a poll.
        view.handleNotesSectionChanged()
        let rebuildsRunningAtArm = view.editorState.runningRebuildTasks.count
        XCTAssertEqual(
            rebuildsRunningAtArm, 1,
            "precondition: a rebuild Task must be running when the switch is armed, or this test would prove nothing " +
            "(handleNotesSectionChanged returned early on one of its own guards)"
        )

        // The switch's save sequence (the part of `LifecycleEntry.run` before `perform`).
        guard let token = SwitchFlushTestSupport.arm(view.editorState, kind: .projectSwitch) else {
            return XCTFail("could not arm the switch token")
        }
        let result = await SwitchFlushTestSupport.flush(view.editorState, token: token, webView: helper.webView)
        let rebuildsRunningAfter = view.editorState.runningRebuildTasks.count

        XCTAssertEqual(result.outcome, .flushed)
        XCTAssertFalse(result.rebuildWaitTimedOut, "the rebuild finished inside step 3's bound; it was awaited, not abandoned")
        XCTAssertEqual(rebuildsRunningAfter, 0, "step 3 awaits the running rebuild to COMPLETION: none may still run")

        // Bounded poll (not a fixed sleep-and-hope): a rebuild that was NOT awaited would land its second row now.
        var markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        let deadline = Date().addingTimeInterval(3)
        while markerRows == 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        }

        // Item 33: name the mechanism this run pinned.
        DebugLog.log(
            .lifecycle,
            "[U4] pinned: FB plus the epoch stamp left one marker row (fb=\(result.fbStatus), marker rows=\(markerRows); " +
            "rebuilds running at arm=\(rebuildsRunningAtArm), after=\(rebuildsRunningAfter), waitTimedOut=\(result.rebuildWaitTimedOut)). " +
            "Step 3's order is proven by LifecycleFlushGuardTests.runningRebuild_isAwaited_andLandsBeforeF. " +
            "NOT proven: a post-poll abort (not built, round C4)."
        )

        XCTAssertEqual(
            markerRows, 1,
            "A switch must leave the old project holding the paragraph exactly once; found \(markerRows) rows containing " +
            "'\(Self.marker)' (2+ means the running Notes rebuild's forced poll re-inserted the still-pending edit " +
            "after the whole-document save, the mechanism of t-e3ec2e7b)"
        )
    }
}

// MARK: - Harness
//
// Copied (not shared) from CloseFlushDuplicateInsertTests.swift, which copied it from QuitFlushDuplicateInsertTests.swift
// -- see that file's header comments for why each piece is shaped the way it is (real NSEvent typing, the heading
// anchor, the rAF shim). Split into an extension to keep the class body under SwiftLint's type_body_length limit.

extension SwitchFlushDuplicateInsertTests {
    private func countRows(containing marker: String, db: ProjectDatabase, pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM block
                WHERE projectId = ? AND markdownFragment LIKE ?
                """, arguments: [pid, "%\(marker)%"]) ?? 0
        }
    }

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
            throw NSError(domain: "switch-flush-duplicate-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(keyUp)
    }

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
                    domain: "switch-flush-duplicate-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(keyUp)
        }
    }

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

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame (see QuitFlushDuplicateInsertTests).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let view = ContentView()
        // Mirrors ContentView+ProjectLifecycle.swift's private configureSyncServices(): the same BlockSyncService
        // instance backs the sequence's drain/poll/fetch and the rebuild handler's forced poll.
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
