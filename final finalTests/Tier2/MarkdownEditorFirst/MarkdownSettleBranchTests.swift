//
//  MarkdownSettleBranchTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 6: the Markdown branches of the settle that follows a
//  Markdown Delete Section's job (StructuralUndoController+MarkdownSettle.swift, EditorViewState+MarkdownLiveText.swift and the one-line
//  hooks in the Rich Text settle files), against the REAL CodeMirror page, a real database and the real writer (`MarkdownClickRig`).
//  Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-U20 (typing made while the settle is held open survives a rebuild whose push the click made stale, and is saved)
//          BREAK: in `EditorViewState.adoptLiveEditorText` (ViewState/EditorViewState+RebuildGuard.swift) delete the first line
//                 `if editorMode == .source { return await adoptLiveMarkdownText(...) }`.
//          FAILS: "pq8 overwritten by Notes rebuild" (the Rich Text body asks the Rich Text web view, gets nothing, and keeps the
//                 database's text the rebuild had just put into `content`).
//   tail   the settle re-posts the Notes and Bibliography rebuilds a click made stale, once no editor-first job is pending.
//          BREAK: in `settleMarkdownManagedRegions` delete the two `NotificationCenter.default.post` lines (or, in
//                 `settleManagedRegionsAtEndOfEditorFirstSettle`, the `if editorState.editorMode == .source { ... return }` line).
//          FAILS: "Notes rebuild not re-posted".
//   B8     a delete job that fails: the editor is swapped back and the user told when nothing was typed since.
//          BREAK: in `runMarkdownStep8` delete the line `gate.swappedBack = await swapBackFailedMarkdownDelete(opId: opId, gateKey: key)`.
//          FAILS: "the section was not put back in the editor".
//   B8     a delete job that fails after the user typed: the editor is left alone and NO alert shows.
//          BREAK: in `putBackAfterFailedEditorFirstOp` (StructuralUndoController+EditorFirstStructural.swift) delete the first line
//                 `if hasMarkdownGate(opId: opId, jobKey: jobKey) { ... return }`.
//          FAILS: "typing wiped by put-back" (the Rich Text put-back pushes the database's document and raises its alert).
//   W8     the page's settle flag is set before the renumber the footnote resync posts and cleared after it, on the page's own FIFO.
//          BREAK: in `resyncAfterEditorFirstDelete` delete the line `defer { unmarkMarkdownSettle(opId: opId) }`.
//          FAILS: "flag still set after settle".
//   F9/M-5 the clear names the settle it belongs to (a compare-and-clear), so an earlier settle's clear cannot drop a later settle's flag.
//          BREAK: in `unmarkMarkdownSettle` send `setStructuralSettleOpId(null)` (without the opId as the second argument).
//          FAILS: "the clear did not name the settle it belongs to".
//   O20    a click that falls back to the old body re-posts the Notes and Bibliography rebuilds a skipped push owed, AFTER the click's
//          hold is released (the rebuilds then read the rows and push a region replace).
//          BREAK: in `performMarkdownEditorFirstDelete` delete the `if outcome == nil, let editorState, ... { ... }` block.
//          FAILS: "Notes rebuild not re-posted on the fallback exit".
//   gate   the settle's wait for step 8 is bounded.
//          BREAK: in `MarkdownStep8Gate.wait` delete the `if clock.now >= end { ... return }` block.   FAILS: "wait did not give up".
//

import Foundation
import WebKit
import XCTest
@testable import final_final

/// Counts the notifications of the given names (synchronously, whatever thread posts them).
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Notification.Name: Int] = [:]
    private var tokens: [NSObjectProtocol] = []

    init(_ names: [Notification.Name]) {
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.bump(name)
            })
        }
    }

    private func bump(_ name: Notification.Name) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: Notification.Name) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name] ?? 0
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}

@MainActor
final class MarkdownSettleBranchTests: XCTestCase {

    private var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.controller.testOrderingSpy = nil
        rig?.controller.testEFSettleHold = nil
        rig?.editorState.lifecycleHost = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."

    private static let footnotedBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n# Chapter 3\n\nThird chapter text.[^3]\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three."

    // MARK: - T-U20 (typing during the settle)

    func testTypingMadeWhileTheSettleIsHeldOpenSurvivesAStaleRebuildTailAndIsSaved() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        rig.editorState.lifecycleHost = QuitFlushTestSupport.host(webView: rig.helper.webView)
        rig.editorState.sourceReparseDebounce = .milliseconds(5)
        let gate = LifecycleEntryHarness.Gate()
        let reached = GateOrderLog()
        rig.controller.testEFSettleHold = {
            reached.note("held")
            await gate.wait()
        }
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let held = await rig.waitUntil { reached.items == ["held"] }
        XCTAssertTrue(held, "the settle never reached its hold")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "premise: step 8 had released the hold before the settle's resyncs")

        // The user types while the settle is parked.
        try await rig.userTypes(" pq8", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("pq8") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")

        // A Notes rebuild read the rows before this click and pushes after it: its stamp is stale. The handler had already put the
        // database's text into `content`; the stale tail must give the editor's own text back (the rows do not have pq8 yet).
        let stamp = rig.editorState.stampRebuildRead()
        rig.editorState.editorFirstClickGeneration &+= 1
        rig.editorState.content = try rig.writerRig.storedText()
        XCTAssertFalse(rig.editorState.content.contains("pq8"), "premise: the database's text lacks the typing")
        let stale = await rig.editorState.skipStaleRebuildTail(stamp, kind: "notes", blockSync: rig.writerRig.sync)
        XCTAssertTrue(stale, "premise: the rebuild's stamp is stale")
        XCTAssertTrue(rig.editorState.managedRegionsNeedRepush, "the skipped push owes the editor a re-push")
        XCTAssertTrue(rig.editorState.content.contains("pq8"), "pq8 overwritten by Notes rebuild")
        XCTAssertTrue(rig.editorState.sourceContent.contains("pq8"), "pq8 overwritten by Notes rebuild (the source copy)")

        gate.open()
        await rig.settleEverything()
        // ContentView arms the re-parse when `content` changes; the rig does it by hand.
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()

        let page = try await rig.pageText()
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(page.contains("pq8"), "pq8 is not in the editor")
        XCTAssertTrue(stored.contains("pq8"), "pq8 is not in the rows")
        XCTAssertFalse(stored.contains("Chapter 3") || page.contains("Chapter 3"), "the deleted chapter came back")
        XCTAssertFalse(rig.editorState.managedRegionsNeedRepush, "the settle left the owed re-push standing")
    }

    // MARK: - The end of the settle

    func testTheSettleRepostsTheNotesAndBibliographyRebuildsOnceNoJobIsPending() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let counter = NotificationCounter([.notesSectionChanged, .bibliographySectionChanged])
        defer { counter.stop() }
        let editorState = rig.editorState
        editorState.managedRegionsNeedRepush = true
        editorState.pendingEditorFirstJobs = 1

        await rig.controller.settleManagedRegionsAtEndOfEditorFirstSettle(editorState: editorState, projectId: rig.pid)
        XCTAssertEqual(counter.count(.notesSectionChanged), 0, "re-posted while an editor-first job was still pending")
        XCTAssertTrue(editorState.managedRegionsNeedRepush, "the owed re-push was dropped while a job was pending")

        editorState.pendingEditorFirstJobs = 0
        await rig.controller.settleManagedRegionsAtEndOfEditorFirstSettle(editorState: editorState, projectId: rig.pid)
        XCTAssertEqual(counter.count(.notesSectionChanged), 1, "Notes rebuild not re-posted")
        XCTAssertEqual(counter.count(.bibliographySectionChanged), 1, "Bibliography rebuild not re-posted")
        XCTAssertFalse(editorState.managedRegionsNeedRepush, "the flag stayed up after the re-post")

        await rig.controller.settleManagedRegionsAtEndOfEditorFirstSettle(editorState: editorState, projectId: rig.pid)
        XCTAssertEqual(counter.count(.notesSectionChanged), 1, "re-posted with nothing owed")
        XCTAssertEqual(counter.count(.bibliographySectionChanged), 1, "re-posted with nothing owed")
    }

    // MARK: - B8: a delete job that fails

    /// Makes the click's job fail: it waits behind a held system sequence while the root heading's row is removed from the database, so
    /// the job finds no section to delete (`rootNotDeletable`) once the sequence is released. Returns the held sequence.
    private func clickWithAJobThatWillFail(rootId: String, userTypes typed: (text: String, after: String)? = nil) async throws -> SystemTicket {
        let ticket = rig.writerRig.hold()
        let outcome = await rig.controller.performSectionDelete(rootId: rootId)
        XCTAssertEqual(outcome, .performed)
        let afterClick = try await rig.pageText()
        XCTAssertFalse(afterClick.contains("Chapter 3"), "premise: the editor already shows the delete")
        if let typed { try await userTypes(typed.text, after: typed.after) }
        try rig.db.write { database in
            try database.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [rootId])
        }
        return ticket
    }

    /// The user types `text` right after the first `marker` in the page, as a keystroke does: a USER-origin transaction. NOT `rig.type`:
    /// that is `setContent`, the application's own push, which the page treats as derived content (no history step; the entry's saved
    /// post-op copy moves along with it while the document still equals it), so a swap-back right after it is correctly accepted.
    /// Only a user-origin change makes the live document differ from the saved copy, which is what the swap-back refuses on.
    private func userTypes(_ text: String, after marker: String) async throws {
        let markerLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(marker))
        let textLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(text))
        let typed = try await rig.helper.webView.evaluateJavaScript(
            """
            (() => {
              const ff = window.FinalFinal;
              const doc = ff.getContentRaw();
              const at = doc.indexOf(\(markerLiteral));
              if (at < 0) return false;
              const before = doc.slice(0, at + \(markerLiteral).length);
              ff.setCursorPosition({ line: before.split('\\n').length, column: before.length - (before.lastIndexOf('\\n') + 1) });
              ff.insertAtCursor(\(textLiteral));
              return true;
            })()
            """)
        XCTAssertEqual(typed as? Bool, true, "premise: the marker \(marker) is in the page")
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains(text), "premise: the typing is in the page")
    }

    func testAFailedDeleteIsSwappedBackWhenNothingWasTypedAndTheUserIsTold() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let chapter3 = try rig.section("Chapter 3")
        let ticket = try await clickWithAJobThatWillFail(rootId: chapter3.id)
        await rig.writerRig.release(ticket)
        await rig.settleEverything()

        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("# Chapter 3") && page.contains("Third chapter text."), "the section was not put back in the editor")
        XCTAssertEqual(rig.controller.testShownAlerts, ["Couldn't Delete Section"], "the user was not told")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed delete's entry is still on the timeline")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed delete's entry kind was kept")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "the failed delete's step-8 gate was kept")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up")
        XCTAssertTrue(rig.editorState.pendingRemovalIds.isEmpty, "the sidebar still hides the section")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("Chapter 3") && stored.contains("Third chapter text."), "the rows do not match the restored editor")
    }

    func testAFailedDeleteLeavesTheEditorAloneAndShowsNoAlertWhenTheUserTypedMeanwhile() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let chapter3 = try rig.section("Chapter 3")
        let ticket = try await clickWithAJobThatWillFail(rootId: chapter3.id, userTypes: (text: " wq3", after: "Second chapter text."))
        await rig.writerRig.release(ticket)
        await rig.settleEverything()

        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("wq3"), "typing wiped by put-back")
        XCTAssertFalse(page.contains("Chapter 3"), "typing wiped by put-back: the section came back over the user's text")
        XCTAssertTrue(rig.controller.testShownAlerts.isEmpty, "typing wiped by put-back: an alert said the section was put back")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed delete's entry is still on the timeline")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed delete's entry kind was kept")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "the failed delete's step-8 gate was kept")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("wq3"), "the typing is not in the rows")
        XCTAssertFalse(stored.contains("Third chapter text."), "the command stands, so the chapter's text is gone from the rows")
    }

    // MARK: - W8 / O10: the page's settle flag

    private func pageCalls() async throws -> [String] {
        let json = try await rig.helper.webView.evaluateJavaScript("JSON.stringify(window.__calls)")
        let data = Data(try XCTUnwrap(json as? String).utf8)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func testTheSettleFlagIsSetBeforeTheRenumberAndClearedAfterItOnThePagesOwnQueue() async throws {
        rig = try await MarkdownClickRig(markdown: Self.footnotedBook, observesPage: true)
        rig.coordinator?.webView = rig.helper.webView   // the coordinator posts the renumber to this view
        // The page logs the two calls it receives, in the order it receives them.
        _ = try await rig.helper.webView.evaluateJavaScript(
            """
            (() => {
              window.__calls = [];
              const ff = window.FinalFinal;
              const setFlag = ff.setStructuralSettleOpId.bind(ff);
              window.__expecting = [];
              ff.setStructuralSettleOpId = (id, expecting) => {
                window.__calls.push('set:' + id);
                if (expecting !== undefined) window.__expecting.push(expecting);
                return setFlag(id, expecting);
              };
              const renumber = ff.renumberFootnotes.bind(ff);
              ff.renumberFootnotes = (mapping) => { window.__calls.push('renumber'); return renumber(mapping); };
              return true;
            })()
            """)
        _ = try await rig.helper.webView.evaluateJavaScript("window.FinalFinal.setStructuralSettleOpId(null)")
        let probe = try await pageCalls()
        XCTAssertEqual(probe, ["set:null"], "premise: the page's functions can be wrapped")
        _ = try await rig.helper.webView.evaluateJavaScript("window.__calls = []; window.__expecting = []")

        let chapter2 = try rig.section("Chapter 2")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter2.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()
        let opId = try XCTUnwrap(rig.controller.efEditorKind.keys.first, "the entry was not recorded")

        // The clear is submitted through the main queue, behind the observer that sends the renumber: allow for that hop.
        var calls: [String] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            calls = try await pageCalls()
            if calls.last == "set:null" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls.first, "set:\(opId.uuidString)", "the flag was not set before the settle's resync: \(calls)")
        XCTAssertEqual(calls.last, "set:null", "flag still set after settle: \(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("set:") }.count, 2, "the flag was set or cleared more than once: \(calls)")
        XCTAssertTrue(calls.contains("renumber"), "premise: the settle's footnote resync renumbered a reference through the page: \(calls)")
        if let firstSet = calls.firstIndex(where: { $0.hasPrefix("set:") }), let lastSet = calls.lastIndex(where: { $0.hasPrefix("set:") }) {
            for (index, call) in calls.enumerated() where call == "renumber" {
                XCTAssertTrue(index > firstSet && index < lastSet, "a renumber reached the page outside the flag: \(calls)")
            }
        }
        XCTAssertEqual(
            rig.markdownWriter.structuralHoldState.settleFlagLog, [opId.uuidString, nil], "the host did not set and clear the flag once each")
        // F9/M-5: the clear carries the settle's own opId, so the page clears only while the flag still holds it.
        let expectingJSON = try await rig.helper.webView.evaluateJavaScript("JSON.stringify(window.__expecting)")
        let expecting = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(expectingJSON as? String).utf8))
        XCTAssertEqual(expecting, [opId.uuidString], "the clear did not name the settle it belongs to: \(expecting)")
    }

    // MARK: - O20: the fallback exit

    /// Records, for each notification of the given names, whether the Markdown writer's structural hold was up when it was posted.
    private final class HeldAtPostLog: @unchecked Sendable {
        private let lock = NSLock()
        private var heldWhenPosted: [Notification.Name: [Bool]] = [:]
        private var tokens: [NSObjectProtocol] = []

        @MainActor
        init(_ names: [Notification.Name], writer: MarkdownBlockWriter) {
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self, weak writer] _ in
                    let held = MainActor.assumeIsolated { writer?.isHeldForStructuralWork ?? true }
                    self?.note(name, held: held)
                })
            }
        }

        private func note(_ name: Notification.Name, held: Bool) {
            lock.lock()
            heldWhenPosted[name, default: []].append(held)
            lock.unlock()
        }

        func posts(_ name: Notification.Name) -> [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return heldWhenPosted[name] ?? []
        }

        func stop() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
        }
    }

    func testAClickThatFallsBackRepostsTheRebuildsASkippedPushOwedAfterItsHoldIsReleased() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let log = HeldAtPostLog([.notesSectionChanged, .bibliographySectionChanged], writer: rig.markdownWriter)
        defer { log.stop() }
        let chapter3 = try rig.section("Chapter 3")
        rig.editorState.managedRegionsNeedRepush = true   // a rebuild's push was skipped while the click's stamp was up
        rig.controller.activeWebView = WKWebView()        // no editor in it: the page call fails, so the click falls back

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertNil(outcome, "premise: the click gave up so the old body runs")
        XCTAssertEqual(log.posts(.notesSectionChanged), [false], "Notes rebuild not re-posted on the fallback exit (or posted while the hold was up)")
        XCTAssertEqual(
            log.posts(.bibliographySectionChanged), [false],
            "Bibliography rebuild not re-posted on the fallback exit (or posted while the hold was up)")
        XCTAssertFalse(rig.editorState.managedRegionsNeedRepush, "the owed re-push was not consumed by the re-post")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0)
    }

    // MARK: - The bound

    func testTheSettlesWaitForStep8GivesUpAfterItsBoundAndReturnsAtOnceWhenFinished() async {
        let gate = MarkdownStep8Gate()
        let gaveUp = await runWithin(5) {
            await gate.wait(bound: .milliseconds(100))
            return true
        }
        XCTAssertEqual(gaveUp, true, "wait did not give up")
        XCTAssertFalse(gate.finished)

        gate.finish()
        let immediate = await runWithin(1) {
            await gate.wait(bound: .seconds(60))
            return true
        }
        XCTAssertEqual(immediate, true, "wait did not return for a finished gate")
    }
}
