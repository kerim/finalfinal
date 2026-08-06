//
//  ZoomWordCountSyncTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — DIAGNOSTIC for "word count not updating while zoomed".
//
//  Reproduces the full editor→DB sync chain with a real Milkdown WKWebView:
//    edit in editor → block-sync diff → BlockSyncService poll → applyBlockChangesFromEditor
//    → stored Block.wordCount changes.
//
//  The control test runs the chain un-zoomed (full document pushed with all block IDs).
//  The zoomed test replicates exactly what ContentView.onZoomToSection does:
//  setContentWithBlockIds(zoomed subset) followed by pushBlockIds(for: range), which
//  flips the JS editor into zoom mode (blockIdZoomMode = true).
//
//  If the control passes and the zoomed test fails, the freeze is in the editor→DB
//  hop while zoomed (not in the GRDB observation layer, which OutlineObservationTests
//  already prove works).
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
@testable import final_final

/// Collects selectionChanged script messages for assertions.
@MainActor
private final class SelectionMessageCollector: NSObject, WKScriptMessageHandler {
    private(set) var received: [String] = []
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        Task { @MainActor in
            self.received.append(text)
        }
    }
}

/// MainActor-isolated one-shot checked-continuation signal. `wait()` suspends
/// until `fire()` is called (or returns immediately if `fire()` already
/// happened). Because both this type and its callers are @MainActor, calls
/// into it never hop actors — they're synchronous when the caller is already
/// on MainActor — which is what makes the event-ordering test below
/// deterministic rather than a race against the scheduler.
@MainActor
private final class Signal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Checked-continuation gate (no sleep) that lets a test hold an in-flight poll
/// cycle deterministically suspended mid-cycle via `testPollCycleHook`, confirm
/// via `waitUntilReached()` that it's genuinely stuck there (not merely about
/// to run), then release it with `open()`.
@MainActor
private final class PollGate {
    private var reached = false
    private var released = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Call from inside the poll cycle (via `testPollCycleHook`).
    func waitAtGate() async {
        reached = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    /// Suspends until some poll cycle has actually reached the gate.
    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    /// Releases whatever is parked at the gate; future arrivals pass straight through.
    func open() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Records a happens-before-ordered sequence of named events. @MainActor (not
/// a true `actor`) so `record()` is a synchronous call from any MainActor
/// context — no suspension point that could reorder events relative to other
/// synchronous MainActor work.
@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

final class ZoomWordCountSyncTests: XCTestCase {

    /// Two sections so we can zoom into the second one.
    private static let doc = """
    # Alpha

    one two three.

    # Beta

    four five six.
    """

    // MARK: - Helpers

    /// Sum of stored block word counts — the same quantity batchWordCounts aggregates.
    private func totalWordCount(_ db: ProjectDatabase, _ pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COALESCE(SUM(wordCount), 0)
                FROM block
                WHERE projectId = ?
                """, arguments: [pid]) ?? 0
        }
    }

    /// Simulate typing by replacing "six" with a longer phrase via the find/replace
    /// API — a real ProseMirror transaction, indistinguishable from an edit for the
    /// block-sync plugin (find/replace does not pause sync).
    @MainActor
    private func editBetaParagraph(_ webView: WKWebView) async throws {
        let findResult = try await webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.find('six'))"
        ) as? String
        let replacedCount = try await webView.evaluateJavaScript(
            "window.FinalFinal.replaceAll('six seven eight nine')"
        ) as? Int
        DebugLog.always("[ZoomWordCountSyncTests] find=\(String(describing: findResult)) replaced=\(String(describing: replacedCount))")
        // detectChanges debounce is 100ms; leave generous headroom
        try await Task.sleep(nanoseconds: 600_000_000)
        let contentAfter = try await webView.evaluateJavaScript(
            "window.FinalFinal.getContent()"
        ) as? String ?? ""
        DebugLog.always("[ZoomWordCountSyncTests] editor content after edit: \(contentAfter.replacingOccurrences(of: "\n", with: "\\n"))")

        // Probe 1: did requestAnimationFrame ever fire? (deferredSnapshotAndUnpause depends on it)
        _ = try await webView.evaluateJavaScript(
            "window.__rafFired = false; requestAnimationFrame(() => { window.__rafFired = true; }); true"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        let rafFired = try await webView.evaluateJavaScript("window.__rafFired") as? Bool
        // Probe 2: are block IDs assigned? (cursor sits at the replace target after find())
        let blockAtCursor = try await webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.getBlockAtCursor())"
        ) as? String
        // Probe 3: pending changes?
        let pending = try await webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        DebugLog.always(
            "[ZoomWordCountSyncTests] rafFired=\(String(describing: rafFired)) "
            + "blockAtCursor=\(String(describing: blockAtCursor)) hasBlockChanges=\(String(describing: pending))"
        )
    }

    /// Keeps the WebView on-screen so requestAnimationFrame fires.
    /// block-sync's deferredSnapshotAndUnpause() relies on rAF; an offscreen
    /// WKWebView never runs it and sync stays paused forever (test artifact).
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
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
        window.orderFront(nil)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on — without this,
        // sync stays paused forever and no edit ever registers (pure test artifact;
        // verified via __rafFired probe).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        return EditorStack(helper: helper, db: db, pid: pid, sync: sync)
    }

    // MARK: - Selection word count push

    /// The selection-stats plugin must push selected text via the
    /// selectionChanged message (debounced), and push '' on deselect.
    /// find() dispatches a real ProseMirror text selection over the match;
    /// replaceCurrent() with identical text collapses it again.
    @MainActor
    func testSelectionChanged_pushesSelectedTextAndClearsOnDeselect() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let sync = stack.sync
        let collector = SelectionMessageCollector()
        helper.webView.configuration.userContentController.add(collector, name: "selectionChanged")
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionChanged") }

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Select the Beta paragraph's text the way a mouse drag does: set the DOM
        // selection over the text node; ProseMirror's DOM observer syncs it into
        // state.selection. (find() only places a collapsed cursor — decorations,
        // not a range selection.) Then wait out the 150ms debounce.
        let selected = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                pm.focus();
                const walker = document.createTreeWalker(pm, NodeFilter.SHOW_TEXT);
                let target = null;
                while (walker.nextNode()) {
                    if (walker.currentNode.textContent.includes('four five six')) {
                        target = walker.currentNode; break;
                    }
                }
                if (!target) return 'no-target';
                const range = document.createRange();
                range.selectNodeContents(target);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return sel.toString();
            })()
            """
        ) as? String
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(
            collector.received.contains { $0.contains("four five six") },
            "selectionChanged must push the selected text (DOM selected: \(String(describing: selected)), got: \(collector.received))"
        )

        // find() places a collapsed cursor → selection cleared → '' push
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.find('four'); true")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(
            collector.received.last, "",
            "deselect must push an empty string (got: \(collector.received))"
        )
    }

    // MARK: - Control (not zoomed)

    @MainActor
    func testControl_editWhileNotZoomed_updatesStoredWordCount() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)

        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try totalWordCount(db, pid)
        try await editBetaParagraph(helper.webView)
        await sync.pollBlockChangesNow()

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            "CONTROL: un-zoomed edit must reach the DB (before=\(before), after=\(after))"
        )
    }

    // MARK: - Reentrancy: forced flush must drain an in-flight poll, then flush fresh

    /// Regression test for a reentrancy bug in `BlockSyncService`'s poll/flush
    /// primitive: a forced flush (`pollBlockChangesNow()`, used before footnote
    /// insertion, bibliography rebuild, and notes rebuild) arriving while a
    /// periodic poll cycle was already mid-flight used to return *immediately*
    /// (the old `isPolling` guard), silently skipping the caller's just-made
    /// edit — live data loss.
    ///
    /// This test forces the exact interleaving deterministically, with no sleep
    /// race: it starts a periodic (unforced) poll cycle and gates it mid-cycle
    /// via `testPollCycleHook` (confirmed via `PollGate.waitUntilReached()` to
    /// be genuinely suspended, not merely about to run), makes a real edit,
    /// then calls a forced flush and records a happens-before-ordered event
    /// sequence — `.flushCalled` when the forced flush starts, `.gateReleased`
    /// when the gated cycle is released, `.flushReturned` when the forced flush
    /// returns.
    ///
    /// The assertion is on that recorded ORDER, not on timing: under the old
    /// buggy `isPolling` guard the order would be `flushCalled, flushReturned,
    /// gateReleased` (the forced flush returns instantly, before the gate is
    /// even opened); under the fix it's `flushCalled, gateReleased,
    /// flushReturned` (the forced flush drains the gated cycle, then runs and
    /// awaits a fresh cycle of its own). A fixed ~200ms-sleep-based assertion
    /// would false-pass on a loaded/slow CI machine if the margin weren't
    /// enough; this ordering assertion cannot false-pass regardless of machine
    /// speed, because it's derived from actual continuation-resume order, not
    /// wall-clock timing.
    @MainActor
    func testForcedFlush_waitsForInFlightPoll_thenFlushesFreshEdit() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try totalWordCount(db, pid)

        let gate = PollGate()
        let events = EventLog()
        sync.testPollCycleHook = { await gate.waitAtGate() }

        // Start a periodic (unforced) poll cycle and let it hang at the gate —
        // simulates a slow in-flight background poll.
        let periodicTask = Task { @MainActor in
            await sync.pollBlockChangesForTest(force: false)
        }
        await gate.waitUntilReached()

        // Make a real edit AFTER the periodic cycle is already stuck mid-flight.
        // This is the exact interleaving that produced live data loss: the
        // stuck cycle's eventual snapshot predates this edit, so a forced flush
        // that merely waited for it (without also running a fresh cycle of its
        // own) would still miss the edit.
        try await editBetaParagraph(helper.webView)

        // Start the forced flush and deterministically confirm it has begun
        // running (reached at least its entry decision) before we open the
        // gate. `forcedStarted.fire()` is the task's first synchronous action;
        // since everything here is @MainActor (a serial executor that doesn't
        // preempt mid-synchronous-execution), by the time `forcedStarted.wait()`
        // resumes in this method, the forced flush has already run its full
        // synchronous prefix — including its `inFlightPoll` entry check — so
        // opening the gate afterward can never race ahead of that decision.
        let forcedStarted = Signal()
        let forcedTask = Task { @MainActor in
            forcedStarted.fire()
            events.record("flushCalled")
            await sync.pollBlockChangesForTest(force: true)
            events.record("flushReturned")
        }
        await forcedStarted.wait()

        events.record("gateReleased")
        gate.open()

        await periodicTask.value
        await forcedTask.value

        let recorded = events.events
        guard let releasedIdx = recorded.firstIndex(of: "gateReleased"),
              let returnedIdx = recorded.firstIndex(of: "flushReturned") else {
            XCTFail("Expected both .gateReleased and .flushReturned events, got \(recorded)")
            return
        }
        XCTAssertEqual(recorded.first, "flushCalled", "forced flush must start before we release the gate, got \(recorded)")
        XCTAssertLessThan(
            releasedIdx, returnedIdx,
            "forced flush must not return before the gated in-flight poll it drained on is released — got order \(recorded)"
        )

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            "forced flush must flush a fresh cycle after draining, so the edit made while the periodic " +
                "cycle was gated must reach the DB (before=\(before), after=\(after))"
        )
    }

    // MARK: - Zoomed: new block created while zoomed (regression for frozen word count)

    /// Reproduces the root cause of "word count not updating while zoomed":
    /// blocks created during zoom got no temp ID (blanket zoom-mode suppression),
    /// were invisible to block-sync, and never reached the DB until zoom-out.
    /// With the fix (suppression scoped to the mini-Notes tail), a paragraph
    /// split while zoomed must produce a DB insert on the next poll.
    @MainActor
    func testZoomed_newBlockWhileZoomed_reachesDatabase() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 300_000_000)

        let blockCountBefore = try db.fetchBlockCount(projectId: pid)

        // Select "six" (places a real selection inside the paragraph), then press
        // Enter via synthetic keydown — ProseMirror's keymap handles it and splits
        // the paragraph, creating a NEW block while zoomed.
        _ = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                window.FinalFinal.find('six');
                const pm = document.querySelector('.ProseMirror');
                pm.focus();
                return pm.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                    bubbles: true, cancelable: true
                }));
            })()
            """
        )
        try await Task.sleep(nanoseconds: 600_000_000)

        let hasChanges = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        await sync.pollBlockChangesNow()

        let blockCountAfter = try db.fetchBlockCount(projectId: pid)
        XCTAssertGreaterThan(
            blockCountAfter, blockCountBefore,
            """
            ZOOMED: paragraph split while zoomed did not reach the DB \
            (blocks before=\(blockCountBefore), after=\(blockCountAfter), \
            hasBlockChanges=\(String(describing: hasChanges))). \
            New blocks created during zoom must get temp IDs and sync live.
            """
        )
    }

    // MARK: - Zoomed: mini-Notes tail must NOT sync (the reason zoom mode exists)

    /// The temp-ID fix must not regress the original protection: the appended
    /// mini-Notes tail (zoom_notes_marker + # Notes + footnote definitions) is
    /// presentation-only and must never be inserted into the DB by block-sync.
    @MainActor
    func testZoomed_miniNotesTail_staysOutOfDatabase() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        // Mirror zoomToSection's mini-Notes append (EditorViewState+Zoom.swift)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)
            + "\n\n<!-- ::zoom-notes:: -->\n# Notes\n\n[^note1]: A footnote definition that must not sync.\n"

        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 500_000_000)

        let blockCountBefore = try db.fetchBlockCount(projectId: pid)

        // Two poll cycles: any temp IDs wrongly assigned to the mini-Notes tail
        // would surface as inserts here.
        await sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        await sync.pollBlockChangesNow()

        let blockCountAfter = try db.fetchBlockCount(projectId: pid)
        XCTAssertEqual(
            blockCountAfter, blockCountBefore,
            "Mini-Notes tail must never be inserted into the DB by block-sync"
        )
        let leaked = try TestFixtureFactory.fetchBlocks(from: db).filter {
            $0.textContent.contains("must not sync") || ($0.blockType == .heading && $0.textContent == "Notes")
        }
        XCTAssertTrue(leaked.isEmpty, "Mini-Notes content leaked into DB: \(leaked.map { $0.textContent })")
    }

    // MARK: - Zoomed

    @MainActor
    func testZoomed_editInsideZoomedSection_updatesStoredWordCount() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        // Replicate EditorViewState.zoomToSection's content assembly:
        // every block from the Beta heading to the end (Beta is the last section).
        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

        // Replicate ContentView.onZoomToSection: push zoomed content + IDs, then
        // pushBlockIds(for: range) which enables JS zoom mode.
        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 300_000_000)

        let before = try totalWordCount(db, pid)
        try await editBetaParagraph(helper.webView)

        // Diagnostic visibility: what does the JS side think it has pending?
        let hasChanges = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        DebugLog.always("[ZoomWordCountSyncTests] zoomed hasBlockChanges=\(String(describing: hasChanges))")

        await sync.pollBlockChangesNow()

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            """
            ZOOMED: edit inside the zoomed section did not reach the DB \
            (before=\(before), after=\(after), hasBlockChanges=\(String(describing: hasChanges))). \
            This reproduces the frozen-word-count-while-zoomed bug.
            """
        )
    }

    // MARK: - Zoomed: heading deleted while zoomed (SectionSyncService.syncZoomedSections deletion path)

    /// Exercises `syncZoomedSections`'s deletion branch directly (via `contentChanged`, the
    /// same entry point `ViewNotificationModifiers` calls) rather than through the block-sync/
    /// WKWebView chain the other tests in this file use. Section-level sync while zoomed is
    /// data-integrity-adjacent — deleting a section's heading while zoomed must remove exactly
    /// that section from the sections table, leave sections outside the zoomed set untouched,
    /// and report the removal via `onZoomedSectionsUpdated`.
    @MainActor
    func testZoomed_headingDeletedWhileZoomed_removesFromDatabase() async throws {
        let fullMarkdown = """
        # Alpha

        Alpha text.

        # Beta

        Beta text.

        # Gamma

        Gamma text.
        """
        let db = try TestFixtureFactory.createTemporary(content: fullMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: pid)

        // Populate the sections table from the full document, as the initial sync would.
        await syncService.syncNow(fullMarkdown)

        let sectionsBefore = try db.fetchSections(projectId: pid)
        XCTAssertEqual(sectionsBefore.map(\.title), ["Alpha", "Beta", "Gamma"])
        guard let alpha = sectionsBefore.first(where: { $0.title == "Alpha" }),
              let beta = sectionsBefore.first(where: { $0.title == "Beta" }),
              let gamma = sectionsBefore.first(where: { $0.title == "Gamma" }) else {
            XCTFail("Expected Alpha, Beta, and Gamma sections after initial sync")
            return
        }

        // Zoom into Beta + Gamma, then delete Gamma's heading from the zoomed content —
        // mirrors what ContentView's zoomed editor sends via contentChanged(_:zoomedIds:).
        let zoomedIds: Set<String> = [beta.id, gamma.id]
        let editedZoomedMarkdown = """
        # Beta

        Beta text.
        """

        var receivedIds: Set<String>?
        syncService.onZoomedSectionsUpdated = { ids in receivedIds = ids }

        syncService.contentChanged(editedZoomedMarkdown, zoomedIds: zoomedIds)
        // contentChanged debounces for 500ms before syncing; leave generous headroom.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let sectionsAfter = try db.fetchSections(projectId: pid)
        XCTAssertEqual(
            sectionsAfter.count, 2,
            "Deleting Gamma's heading while zoomed must remove exactly one section, got \(sectionsAfter.map(\.title))"
        )
        XCTAssertFalse(
            sectionsAfter.contains { $0.id == gamma.id },
            "Gamma must be removed from the database after its heading was deleted while zoomed"
        )
        XCTAssertTrue(
            sectionsAfter.contains { $0.id == alpha.id },
            "Alpha (outside the zoomed set) must be untouched by the zoomed deletion"
        )
        XCTAssertTrue(
            sectionsAfter.contains { $0.id == beta.id },
            "Beta must remain — only Gamma's heading was deleted"
        )
        XCTAssertEqual(
            receivedIds, [beta.id],
            "onZoomedSectionsUpdated must report the deleted section removed from the zoomed set"
        )
    }
}
