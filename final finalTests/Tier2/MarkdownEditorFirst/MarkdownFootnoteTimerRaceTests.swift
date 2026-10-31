//
//  MarkdownFootnoteTimerRaceTests.swift
//  final finalTests
//
//  t-f1a22aa7 (Phase 4c, job 1: the footnote timer against a Markdown section command), round 2b: the Tier 2 rig tests, against the REAL
//  CodeMirror page, a real database and the real writer (`MarkdownClickRig`). The race: in Markdown mode the 3-second footnote timer
//  (`FootnoteSyncService.fireBurst`) could come due while a section command (Delete, drag, Duplicate, Version History restore) was still
//  finishing. Its renumber then reached the page outside the command's settle flag, so it was a Cmd-Z step of its own and the Notes were
//  relabelled but not sorted, and the settle's own resync skipped at the committed-hash guard. The fix makes the timer stand aside (and
//  re-arm) while `EditorViewState.hasUnfinishedStructuralWork`, and moves a drag's "forget the committed Notes hash" into the footnote
//  resync. This file holds the tests of the Delete and Duplicate commands, the hold on its own and the Cmd-Z counts; the drag's are in
//  MarkdownEditorFirstReorderTests+TimerRace.swift, the restore's in
//  MarkdownEditorFirstRestoreTests+TimerRace.swift. The shared setup is at the top of this file. Needs `cd web && pnpm build` first.
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  THE SETUP EVERY RACE TEST FOLLOWS (plan-v2 Step 5):
//   (1) `testEFSettleHold` parks the command's settle on a gate (the command's job has applied, its resyncs have not run);
//   (2) once the settle is parked, the user types;
//   (3) `runAppFootnoteCheck()` does what the app does on every content change, and the test asserts the PREMISE that it armed a burst
//       ("premise: the app's check armed no burst");
//   (4) `waitForBurstDue()` waits for the timer to come due, and the test asserts the premise that the timer SAW the command's unfinished
//       work (the DEBUG counter is at least 1: "the burst never saw the command's unfinished work (hook not wired)");
//   (5) only then the gate is opened and the settle runs to its end.
//  The page's calls to `setStructuralSettleOpId` and `renumberFootnotes` are logged (the W8 pattern of MarkdownSettleBranchTests), so
//  "the renumber came inside the settle flag" is the page's own call order: [set:<op>, renumber, set:null].
//
//  Break patches (docs/architecture/write-queue-plan/phase4c/footnote-timer/break-patches/, README.md there lists all of them), and what
//  each test shows under them. A failure line is the message of the assertion that goes red:
//
//   R1, R1i, R2   BP-A (burst writes while the command is unfinished)    FAILS: "the timer's renumber reached the page outside the settle
//                 flag: [renumber, set:<op>, set:null]" (R1i can only show the renumber BEFORE the flag: it asserts that order).
//                 BP-C (hook not wired)                                  FAILS: "the burst never saw the command's unfinished work (hook not wired)"
//   R5            BP-A   FAILS: "the timer wrote while the Markdown hold was up"      BP-C, BP-D   FAIL: the hook-not-wired premise
//                 BP-B (no re-arm)   FAILS: "the burst that stood aside never landed after the hold was released"
//   R6            BP-A   FAILS: "the second Cmd-Z did not bring Chapter 2 back (an extra renumber step was in the way)"
//

import Foundation
import WebKit
import XCTest
@testable import final_final

// MARK: - Shared setup

/// Counts the footnote service's notifications while it lives (synchronously, whatever thread posts them). The footnote write's
/// `prepare` posts `.renumberFootnotes` and its commit posts `.notesSectionChanged`: either one means the burst WROTE.
final class TimerRaceNotificationTally: @unchecked Sendable {
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

    /// Posts that mean "a footnote write has started or finished".
    var writePosts: Int { count(.renumberFootnotes) + count(.notesSectionChanged) }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}

/// The command's settle, parked at the DEBUG seam `testEFSettleHold` until `open()`. The command's job has applied by then; the footnote,
/// bibliography and section resyncs have not run.
@MainActor
final class TimerRaceSettleHold {
    let gate = LifecycleEntryHarness.Gate()
    let reached = GateOrderLog()

    init(controller: StructuralUndoController) {
        controller.testEFSettleHold = { [gate, reached] in
            reached.note("held")
            await gate.wait()
        }
    }

    /// Opening twice is harmless (the gate stays open), so a test can open it in a `defer` as well.
    func open() { gate.open() }

    func waitUntilReached(in rig: MarkdownClickRig) async -> Bool {
        await rig.waitUntil { !self.reached.items.isEmpty }
    }
}

/// What a race test reads off the page and the footnote service. Made by `MarkdownClickRig.armTimerRace`.
@MainActor
final class TimerRaceProbe {
    let rig: MarkdownClickRig
    let tally = TimerRaceNotificationTally([.renumberFootnotes, .notesSectionChanged])

    init(rig: MarkdownClickRig) {
        self.rig = rig
    }

    func stop() {
        tally.stop()
    }

    /// The page's recorded calls to `setStructuralSettleOpId` ("set:<id>" / "set:null") and `renumberFootnotes` ("renumber"), in order.
    func pageCalls() async throws -> [String] {
        let json = try await rig.helper.webView.evaluateJavaScript("JSON.stringify(window.__calls)")
        return try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(json as? String).utf8))
    }

    /// The same calls with the settle's op id shown as `<op>`: the shape the assertion messages promise.
    static func shown(_ calls: [String]) -> [String] {
        calls.map { $0.hasPrefix("set:") && $0 != "set:null" ? "set:<op>" : $0 }
    }

    /// The renumber the settle's footnote resync posts reaches the page through the main queue and the page's own FIFO, and the flag's
    /// clear goes the same way: waits (bounded) until the last recorded call is the clear. Returns the calls, shown.
    func callsOnceTheFlagIsCleared(seconds: Double = 5) async throws -> [String] {
        var calls = try await pageCalls()
        let deadline = ContinuousClock.now + .seconds(seconds)
        while calls.last != "set:null", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            calls = try await pageCalls()
        }
        return Self.shown(calls)
    }

    /// Waits (bounded) for the burst's timer to come due: the DEBUG counter of deadlines that arrived while the command was unfinished
    /// reaches `minimumChecks`, OR a footnote write has started (a `.renumberFootnotes` / `.notesSectionChanged` post), which is what a
    /// timer that does NOT stand aside does. The test asserts which of the two it was.
    func waitForBurstDue(minimumChecks: Int = 1, seconds: Double = 5) async {
        let footnotes = rig.footnotes
        let tally = tally
        _ = await rig.waitUntil(seconds) {
            footnotes.testBurstDueDuringStructuralWorkCount >= minimumChecks || tally.writePosts > 0
        }
    }

    static let hookNotWired = "the burst never saw the command's unfinished work (hook not wired)"
    static let outsideTheFlag = "the timer's renumber reached the page outside the settle flag"

    /// Steps (3) and (4) of the setup: the app's check, the premise that it armed a burst, the wait for the timer, the premise that it
    /// saw the command's unfinished work. Synchronous up to the premise on purpose (no pause between the check and the assertion).
    func armTheBurstAndWaitForTheTimer(content: String? = nil, minimumChecks: Int = 1) async {
        rig.runAppFootnoteCheck(content: content)
        XCTAssertTrue(rig.footnotes.testHasPendingUpdate, "premise: the app's check armed no burst")
        await waitForBurstDue(minimumChecks: minimumChecks)
        XCTAssertGreaterThanOrEqual(rig.footnotes.testBurstDueDuringStructuralWorkCount, 1, Self.hookNotWired)
    }

    /// Step (5) and the shared claim of R1, R2 and R3: the page was called [set:<op>, renumber, set:null], nothing is waiting any more.
    func assertTheRenumberCameInsideTheFlag() async throws {
        let calls = try await callsOnceTheFlagIsCleared()
        XCTAssertEqual(calls, ["set:<op>", "renumber", "set:null"], "\(Self.outsideTheFlag): \(calls)")
        XCTAssertFalse(rig.footnotes.testHasPendingUpdate, "the settle's resync left the burst that stood aside waiting")
    }

    /// The labels of the definition lines (`[^N]: ...`) of a page, in the order the page holds them.
    static func definitionLabels(in page: String) -> [String] {
        page.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("[^"), let close = line.range(of: "]:") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        }
    }
}

extension MarkdownClickRig {

    /// The set-up a race test needs and the rig does not do by itself.
    ///  - `footnotes.systemWriter`: the service writes through the writer's queue, as in the app. Without it the service takes its
    ///    direct-write branch, which BLOCKS the main thread on a held job's write transaction under a break patch (judge must-fix T2/T7).
    ///  - `coordinator.webView`: the coordinator posts the service's renumber to this page (judge must-fix T2/T7).
    ///  - the timer: `debounce` is the burst's wait (R1i uses 0), `recheck` the stand-aside's re-check wait.
    ///  - the service is PRIMED (one resync of the document as it stands has committed its references), as it always is by the time a
    ///    user runs a command; the notification tally starts after that, and the page's call log after that too.
    func armTimerRace(debounce: TimeInterval = 0.05, recheck: TimeInterval = 0.05) async throws -> TimerRaceProbe {
        footnotes.systemWriter = SystemWriter(blockSync: writerRig.sync)
        coordinator?.webView = helper.webView
        footnotes.debounceInterval = debounce
        footnotes.standAsideRecheck = recheck
        let text = editorState.content
        await footnotes.resyncNow(
            footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: text), projectId: pid, fullContent: text)
        XCTAssertFalse(footnotes.lastKnownRefs.isEmpty, "premise: the priming resync committed the document's references")
        _ = try await helper.webView.evaluateJavaScript(
            """
            (() => {
              window.__calls = [];
              const ff = window.FinalFinal;
              const setFlag = ff.setStructuralSettleOpId.bind(ff);
              ff.setStructuralSettleOpId = (id, expecting) => { window.__calls.push('set:' + id); return setFlag(id, expecting); };
              const renumber = ff.renumberFootnotes.bind(ff);
              ff.renumberFootnotes = (mapping) => { window.__calls.push('renumber'); return renumber(mapping); };
              return true;
            })()
            """)
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.setStructuralSettleOpId(null)")
        let wrapped = try await helper.webView.evaluateJavaScript("JSON.stringify(window.__calls)")
        XCTAssertEqual(wrapped as? String, "[\"set:null\"]", "premise: the page's functions can be wrapped")
        _ = try await helper.webView.evaluateJavaScript("window.__calls = []")
        return TimerRaceProbe(rig: self)
    }

    /// What the app does on every content change (Views/ViewNotificationModifiers.swift, `syncCitationsAndFootnotes`): the footnote
    /// service is asked to check the references of the content record. SYNCHRONOUS on purpose: a test asserts that a burst is armed on the
    /// line after it, before anything can suspend. `content` defaults to the content record.
    func runAppFootnoteCheck(content: String? = nil) {
        let text = content ?? editorState.content
        footnotes.checkAndUpdateFootnotes(
            footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: text), projectId: pid, fullContent: text)
    }

    /// The user types `text` right after `marker` (a USER-origin keystroke) and the content record has it.
    func typeAndWaitForRecord(_ text: String, after marker: String) async throws {
        try await userTypes(text, after: marker)
        let reported = await waitUntil { self.editorState.content.contains(text) }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
    }

    /// The user places the cursor right after `marker` and inserts a footnote the way `/footnote` does (`window.FinalFinal.insertFootnote()`:
    /// the page renumbers its own references and definitions at once and answers with the new label).
    func insertFootnote(after marker: String) async throws -> String {
        let markerLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(marker))
        let answer = try await helper.webView.evaluateJavaScript(
            """
            (() => {
              const ff = window.FinalFinal;
              const doc = ff.getContentRaw();
              const at = doc.indexOf(\(markerLiteral));
              if (at < 0) return null;
              const before = doc.slice(0, at + \(markerLiteral).length);
              ff.setCursorPosition({ line: before.split('\\n').length, column: before.length - (before.lastIndexOf('\\n') + 1) });
              return ff.insertFootnote();
            })()
            """)
        return try XCTUnwrap(answer as? String, "premise: the marker \(marker) is in the page and the page inserted a footnote")
    }

    /// The Swift half of an immediate insertion (`ContentView.handleFootnoteInsertedImmediate`): the synchronous step, then the write.
    func commitImmediateInsertion(label: String) async {
        let generation = footnotes.beginImmediateInsertion()
        await footnotes.commitImmediateInsertion(label: label, projectId: pid, generation: generation)
    }

    /// The labels of the Notes definition rows of the database, in document order.
    func notesRowLabels() throws -> [String] {
        try db.fetchBlocks(projectId: pid)
            .filter { $0.isNotes && $0.blockType != .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { row in
                let fragment = row.markdownFragment
                guard fragment.hasPrefix("[^"), let close = fragment.range(of: "]:") else { return nil }
                return String(fragment[fragment.index(fragment.startIndex, offsetBy: 2)..<close.lowerBound])
            }
    }

    /// A real Cmd-Z / Cmd-Shift-Z; waits until the page satisfies `condition`, then until the structural gate and everything the press
    /// started have finished (the shape of MarkdownQuickUndoTests.press).
    @discardableResult
    func pressAndWait(_ direction: String, until condition: (String) -> Bool, _ message: String) async throws -> String {
        try await press(direction)
        let text = try await waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await waitUntil { self.editorState.structuralGate.isIdle }
        await settleEverything()
        return text
    }

    /// Frees a job-body hold after `seconds` whatever the test does: a hold parks the writer's thread inside the job's write transaction,
    /// so a break patch that lets a second command through could otherwise freeze the main thread and the test could never release it.
    func releaseAfterWatchdog(_ hold: JobHold, seconds: Double = 15) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            for _ in 0..<8 { hold.release() }
        }
    }
}

// MARK: - The tests

@MainActor
final class MarkdownFootnoteTimerRaceTests: XCTestCase {

    var rig: MarkdownClickRig!
    var probe: TimerRaceProbe?
    var settleHold: TimerRaceSettleHold?
    var heldJobs: [MarkdownClickRig.JobHold] = []

    override func tearDown() async throws {
        probe?.stop()
        probe = nil
        settleHold?.open()
        settleHold = nil
        for hold in heldJobs { for _ in 0..<8 { hold.release() } }
        heldJobs = []
        rig?.controller.testEFJobBodyHold = nil
        rig?.controller.testEFSettleHold = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    /// Three chapters with one footnote each, and the Notes (the footnoted book of MarkdownSettleBranchTests).
    static let footnotedBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n# Chapter 3\n\nThird chapter text.[^3]\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three."

    /// A rig on the footnoted book, armed for the race; `holdsSettle`: the command's settle parks at its hold until the test opens it.
    private func startRig(routesUndo: Bool = false, debounce: TimeInterval = 0.05, holdsSettle: Bool = true) async throws -> TimerRaceProbe {
        rig = try await MarkdownClickRig(markdown: Self.footnotedBook, observesPage: true, routesUndo: routesUndo)
        let armed = try await rig.armTimerRace(debounce: debounce)
        probe = armed
        if holdsSettle { settleHold = TimerRaceSettleHold(controller: rig.controller) }
        return armed
    }

    // MARK: - R1: Delete

    // CLAIM: Chapter 2 is deleted and the settle is parked; the user types a letter; the app's check arms a burst for the references
    // [1, 3] and the timer comes due WHILE the settle is parked. It must stand aside: the only renumber the page receives is the
    // settle's own, between the flag's set and clear (one Cmd-Z step, the Notes sorted), and the third chapter's reference reads [^2].
    func testDeleteTheTimerDueDuringTheHeldSettleRenumbersOnlyInsideTheSettleFlag() async throws {
        let armed = try await startRig()
        let chapter2 = try rig.section("Chapter 2")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter2.id)
        XCTAssertEqual(outcome, .performed)
        let held = await settleHold?.waitUntilReached(in: rig)
        XCTAssertEqual(held, true, "the settle never reached its hold")
        try await rig.typeAndWaitForRecord(" q", after: "First chapter text.[^1]")

        await armed.armTheBurstAndWaitForTheTimer()
        settleHold?.open()
        await rig.settleEverything()

        try await armed.assertTheRenumberCameInsideTheFlag()
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("Third chapter text.[^2]"), "the third chapter's reference was not renumbered to 2: \(page)")
        XCTAssertEqual(rig.footnotes.lastKnownRefs, ["1", "2"], "the settle's resync did not commit the renumbered references")
    }

    // MARK: - R1i: Delete, the timer due at once

    // CLAIM: the same with the burst due straight after the click returns (the interval 0) and the command's JOB still held: the window
    // before the settle exists, where only the writer's hold and the job's registry entry say the command is unfinished. The timer's
    // renumber is posted when its write is RESERVED (not when the writer gets to it), so a timer that did not stand aside would put its
    // renumber on the page inside the held job, BEFORE the settle's flag. This asserts the order and shows both positions.
    func testDeleteTheTimerDueAtOnceWhileTheJobIsHeld() async throws {
        let armed = try await startRig(debounce: 0, holdsSettle: false)
        let hold = rig.holdNextJob()
        heldJobs.append(hold)
        rig.releaseAfterWatchdog(hold)
        let chapter2 = try rig.section("Chapter 2")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter2.id)
        XCTAssertEqual(outcome, .performed)

        await armed.armTheBurstAndWaitForTheTimer()   // no pause between the click and the check
        hold.release()
        await rig.settleEverything()

        let calls = try await armed.callsOnceTheFlagIsCleared()
        let flagSet = calls.firstIndex(of: "set:<op>")
        let firstRenumber = calls.firstIndex(of: "renumber")
        DebugLog.log(
            .lifecycle,
            "[R1i] page calls \(calls): first set at \(String(describing: flagSet)), first renumber at \(String(describing: firstRenumber))")
        XCTAssertNotNil(flagSet, "the settle never set its flag: \(calls)")
        XCTAssertNotNil(firstRenumber, "the page was never told to renumber: \(calls)")
        if let flagSet, let firstRenumber {
            XCTAssertLessThan(
                flagSet, firstRenumber,
                "\(TimerRaceProbe.outsideTheFlag): \(calls) (flag set at \(flagSet), first renumber at \(firstRenumber))")
        }
        XCTAssertEqual(calls, ["set:<op>", "renumber", "set:null"], "\(TimerRaceProbe.outsideTheFlag): \(calls)")
        XCTAssertFalse(rig.footnotes.testHasPendingUpdate, "the settle's resync left the burst that stood aside waiting")
    }

    // MARK: - R2: Duplicate

    // CLAIM: Chapter 1 is duplicated (the copy shares the original's labels, so the Duplicate itself needs no renumber) and the settle is
    // parked; the user types a new reference ` see[^9]` at the end of Chapter 3 (the label 9 becomes 4); the timer comes due while the
    // settle is parked and stands aside; the only renumber is the settle's, inside the flag.
    func testDuplicateTheTimerDueDuringTheHeldSettleRenumbersOnlyInsideTheSettleFlag() async throws {
        let armed = try await startRig()
        let chapter1 = try rig.section("Chapter 1")
        let outcome = await rig.controller.performSectionDuplicate(rootId: chapter1.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        let held = await settleHold?.waitUntilReached(in: rig)
        XCTAssertEqual(held, true, "the settle never reached its hold")
        try await rig.typeAndWaitForRecord(" see[^9]", after: "Third chapter text.[^3]")

        await armed.armTheBurstAndWaitForTheTimer()
        settleHold?.open()
        await rig.settleEverything()

        try await armed.assertTheRenumberCameInsideTheFlag()
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("see[^4]"), "the new reference was not renumbered to 4: \(page)")
        XCTAssertEqual(rig.footnotes.lastKnownRefs, ["1", "2", "3", "4"], "the settle's resync did not commit the renumbered references")
    }

    // MARK: - R5: the Markdown hold alone

    // CLAIM: no command, no job: only the writer's structural hold is up (a click's first page change, before its job is registered, is
    // such a window). The app's check arms a burst for a changed reference list and the timer comes due; with the hold the registry does
    // not know about, it must STILL stand aside (twice, to show the re-check), and write nothing. Once the hold is released the burst
    // lands.
    func testTheMarkdownHoldAloneMakesTheTimerStandAside() async throws {
        let armed = try await startRig(holdsSettle: false)
        let hold = rig.markdownWriter.beginStructuralHold()
        defer { hold.release() }
        XCTAssertFalse(rig.editorState.efJobRegistry.hasUnsettledWork, "premise: no job is registered, the hold stands alone")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the Markdown hold is up")

        let withoutTheSecondReference = Self.footnotedBook.replacingOccurrences(of: "Second chapter text.[^2]", with: "Second chapter text.")
        await armed.armTheBurstAndWaitForTheTimer(content: withoutTheSecondReference, minimumChecks: 2)

        XCTAssertEqual(armed.tally.writePosts, 0, "the timer wrote while the Markdown hold was up")
        XCTAssertTrue(rig.footnotes.testHasPendingUpdate, "the burst that stood aside lost its waiting snapshot")
        XCTAssertEqual(rig.footnotes.lastKnownRefs, ["1", "2", "3"], "the timer committed references while the Markdown hold was up")

        hold.release()
        let landed = await rig.waitUntil { self.rig.footnotes.lastKnownRefs == ["1", "2"] }
        XCTAssertTrue(landed, "the burst that stood aside never landed after the hold was released")
    }

    // MARK: - R6: the Cmd-Z counts

    // CLAIM: R1's setup, with the real Cmd-Z route. The typed letter stays in the document. With the fix the settle's renumber is not an
    // undo step of its own, so: Cmd-Z #1 takes the letter out (Chapter 2 is still gone), Cmd-Z #2 brings Chapter 2 and its reference
    // back, Cmd-Shift-Z #1 takes Chapter 2 out again, Cmd-Shift-Z #2 puts the letter back. A timer renumber outside the flag would be a
    // step of its own, so Cmd-Z #2 would only have taken the letter out, and a third press would be needed.
    func testAfterAHeldSettleTheLetterThenTheDeleteAreUndoneAndRedone() async throws {
        let armed = try await startRig(routesUndo: true)
        let chapter2 = try rig.section("Chapter 2")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter2.id)
        XCTAssertEqual(outcome, .performed)
        let held = await settleHold?.waitUntilReached(in: rig)
        XCTAssertEqual(held, true, "the settle never reached its hold")
        try await rig.typeAndWaitForRecord(" zq7", after: "First chapter text.[^1]")

        await armed.armTheBurstAndWaitForTheTimer()
        settleHold?.open()
        await rig.settleEverything()
        let settled = try await rig.pageText()
        XCTAssertTrue(settled.contains("zq7"), "premise: the letter is on the page")
        XCTAssertFalse(settled.contains("Second chapter text."), "premise: Chapter 2 is gone")

        let afterFirstUndo = try await rig.pressAndWait(
            "undo", until: { !$0.contains("zq7") }, "Cmd-Z #1 did not take the typed letter out")
        XCTAssertFalse(afterFirstUndo.contains("Second chapter text."), "Cmd-Z #1 brought Chapter 2 back as well")
        try await rig.pressAndWait(
            "undo", until: { $0.contains("Second chapter text.[^2]") },
            "the second Cmd-Z did not bring Chapter 2 back (an extra renumber step was in the way)")
        let afterFirstRedo = try await rig.pressAndWait(
            "redo", until: { !$0.contains("Second chapter text.") }, "Cmd-Shift-Z #1 did not take Chapter 2 out again")
        XCTAssertFalse(afterFirstRedo.contains("zq7"), "Cmd-Shift-Z #1 put the letter back as well")
        try await rig.pressAndWait(
            "redo", until: { $0.contains("zq7") && !$0.contains("Second chapter text.") },
            "Cmd-Shift-Z #2 did not put the typed letter back")
    }
}
