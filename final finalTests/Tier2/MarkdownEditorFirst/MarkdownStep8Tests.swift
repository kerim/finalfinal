//
//  MarkdownStep8Tests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 6: step 8 of the Markdown Delete Section click
//  (`runMarkdownStep8`, StructuralUndoController+MarkdownSettle.swift) and the order it gives the settle, against the REAL CodeMirror page,
//  a real database and the real writer (`MarkdownClickRig`). Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-U20 (typing before the click, during step 8's wait for the write in flight, and after it; all of it USER-origin typing. The
//          typing before the click is checked in the rows while the job is still held, so only the click's own batch can explain it)
//          BREAK: in `runMarkdownStep8` move the two lines of (b) (`let live: String?` and the `if let readLive ...` line) above (a), the
//                 `while let pending = writer.inFlight { await pending.value }` loop.
//          FAILS: "typing missing from rows after settle: mn5" (and "step 8 read the page before the write in flight had finished").
//   T-U23 (the settle starts after the flush; no row goes back to older text afterwards, O25)
//          BREAK 1: in `editorFirstJobSettled` (StructuralUndoController+EditorFirstDelete.swift) delete the line
//                   `await awaitMarkdownStep8(opId: opId, jobKey: jobKey, keepsGateForPutBack: !outcome.isApplied)`.
//          FAILS: "row regressed: last keystroke lost after flush" (the rows the settle starts from lack the keystroke) and
//                 "the settle's resyncs started before the flush had applied".
//          BREAK 2: in `markdownStep8Turn` delete `editorState.adoptMarkdownPageText(live)   // O25`.
//          FAILS: "row regressed: last keystroke lost after flush" (the kept re-parse fire reads the older content record and writes it back).
//   T-U10 extended (the Notes definitions the editor removed are never sent as deletes by the typing save)
//          BREAK: in `MarkdownBlockDiff.DiffBuilder.addRemoved` (Services/MarkdownBlockDiff.swift) delete the branch
//                 `else if row.isNotes { filtered.notesDeletes += 1 }`, the production pre-filter that keeps removed Notes definitions out
//                 of a batch (they are the footnote service's rows).
//          FAILS: "definitions deleted" (the rows at the flush lack `[^3]: Note three.`) and, with no typing, "the flush was not filtered-only".
//
//  Not shown by a unit test: the Cmd-Z of this delete (a later round).
//

import Foundation
import XCTest
@testable import final_final

@MainActor
final class MarkdownStep8Tests: XCTestCase {

    private var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.controller.testOrderingSpy = nil
        rig?.controller.testEFSettleHold = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."

    private static let footnotedBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n# Chapter 3\n\nThird chapter text.[^3][^4]\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three.\n\n[^4]: Note four."

    // MARK: - T-U20

    func testTypingBeforeDuringTheWaitForTheWriteInFlightAndAfterIsAllInTheRows() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let chapter3 = try rig.section("Chapter 3")
        let hold = rig.holdNextJob()

        // (1) typing before the click: the click's own batch saves it
        try await rig.userTypes(" bb2", after: "First chapter text.")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        // The job is held, so step 8's flush has saved nothing yet: only the click's own batch can have put "bb2" into the rows now.
        let batchSaved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("bb2")) == true }
        XCTAssertTrue(batchSaved, "typing made before the click is not in the rows before the job ran")

        // A held system sequence goes behind the (held) job: a write reserved after it waits for it.
        let ticket = rig.writerRig.hold()
        // (2) typing while the job is held. The write of this text is the one in flight when step 8 begins (a bypass write, which the
        // hold does not stop): the spy starts it in the same synchronous turn as step 8's first line.
        try await rig.userTypes(" yy4", after: "Second chapter text.")
        let inFlightText = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        let log = GateOrderLog()
        let writer = rig.markdownWriter
        let (db, pid, sync) = (rig.db, rig.pid, rig.writerRig.sync)
        rig.controller.testOrderingSpy = { step in
            log.note(step)
            if step == "md8Begin" {
                _ = writer.prepareStructuralClick(text: inFlightText, database: db, projectId: pid, service: sync, refire: {})
            }
        }

        hold.release()
        let begun = await rig.waitUntil { log.items.contains("md8Begin") }
        XCTAssertTrue(begun, "step 8 never began")
        XCTAssertNotNil(writer.inFlight, "premise: a write is in flight when step 8 begins")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(log.items.contains("md8InFlightDone"), "premise: step 8 waits for the write in flight")

        // (3) typing during that wait: only a live read made AFTER the wait has it
        try await rig.userTypes(" mn5", after: "Second chapter text. yy4")
        await rig.writerRig.release(ticket)
        await rig.settleEverything()

        let stored = try rig.writerRig.storedText()
        let page = try await rig.pageText()
        for typed in ["bb2", "yy4", "mn5"] {
            XCTAssertTrue(stored.contains(typed), "typing missing from rows after settle: \(typed)")
            XCTAssertTrue(page.contains(typed), "typing missing from the editor after settle: \(typed)")
        }
        XCTAssertFalse(stored.contains("Chapter 3"), "the deleted chapter is still in the rows")
        XCTAssertFalse(page.contains("Chapter 3"), "the deleted chapter is back in the editor")
        XCTAssertFalse(writer.isHeldForStructuralWork, "the hold is still up")
        let step8 = log.items.filter { $0.hasPrefix("md8") }
        XCTAssertEqual(
            step8, ["md8Begin", "md8InFlightDone", "md8Read", "md8Reserved", "md8FlushApplied"],
            "step 8 read the page before the write in flight had finished (or skipped a step)")
    }

    // MARK: - T-U23

    func testTheSettleStartsOnlyAfterTheFlushAndNoRowGoesBackToOlderTextAfterwards() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        rig.editorState.sourceReparseDebounce = .milliseconds(5)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)

        // A re-parse fire comes due while the hold is up: it reserves nothing, and the hold keeps its refire.
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        XCTAssertNotNil(rig.markdownWriter.structuralHoldState.heldRefire, "premise: the held fire kept its refire")

        // The user types a key. The page's report reaches the content record, and the record is then put back to the older text by hand:
        // in the app the record trails the page by the page's 50 ms report delay, and the job lands inside it.
        try await rig.userTypes(" kp9", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("kp9") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        rig.editorState.content = rig.editorState.content.replacingOccurrences(of: " kp9", with: "")
        XCTAssertFalse(rig.editorState.content.contains("kp9"), "premise: the record trails the page")

        let log = GateOrderLog()
        let rowsAtSettle = GateOrderLog()
        let writerRig = rig.writerRig
        let editorState = rig.editorState
        rig.controller.testOrderingSpy = { step in log.note(step) }
        rig.controller.testEFSettleHold = {
            log.note("settleResyncs")
            rowsAtSettle.note((try? writerRig.storedText()) ?? "")
            rowsAtSettle.note(editorState.content)
        }

        hold.release()
        await rig.settleEverything()
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()

        let order = log.items.filter { $0 == "md8FlushApplied" || $0 == "settleResyncs" }
        XCTAssertEqual(order, ["md8FlushApplied", "settleResyncs"], "the settle's resyncs started before the flush had applied")
        XCTAssertEqual(rowsAtSettle.items.count, 2, "premise: the settle was reached once")
        XCTAssertTrue(rowsAtSettle.items.first?.contains("kp9") == true, "row regressed: last keystroke lost after flush (at the settle's start)")
        XCTAssertTrue(rowsAtSettle.items.last?.contains("kp9") == true, "the content record did not take the live text before the settle")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("kp9"), "row regressed: last keystroke lost after flush")
        XCTAssertFalse(stored.contains("Chapter 3"), "the deleted chapter is still in the rows")
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("kp9"), "the keystroke is gone from the editor")
        XCTAssertTrue(rig.editorState.content.contains("kp9"), "the content record lost the keystroke")
    }

    // MARK: - T-U10 extended

    /// Footnoted chapter, typing before the click and while the job is held. The editor removes the Notes definitions only chapter 3 used
    /// (`[^3]:` and `[^4]:`) together with the chapter, and the rows still hold them until the settle's footnote resync (the job does not
    /// touch Notes). Step 8's flush, which diffs the editor's text against those rows, must NOT send them as deletes: the pre-filter
    /// keeps them out of the batch. The typing in the batch is saved, the definitions stay until the footnote service removes them, and
    /// no label is left twice.
    func testNotesDefinitionsTheEditorRemovedAreNotSentAsDeletesByTheFlushThatSavesTyping() async throws {
        rig = try await MarkdownClickRig(markdown: Self.footnotedBook, observesPage: true)
        XCTAssertTrue(try rig.writerRig.storedText().contains("[^3]: Note three."), "premise: the rows hold the definition chapter 3 used")
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        try await rig.userTypes(" zq7", after: "First chapter text.[^1]")

        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let afterClick = try await rig.pageText()
        XCTAssertFalse(
            afterClick.contains("[^3]:") || afterClick.contains("[^4]:"), "premise: the editor removed the definitions only chapter 3 used")
        XCTAssertTrue(afterClick.contains("[^1]: Note one.") && afterClick.contains("[^2]: Note two."), "premise: the others stay")
        try await rig.userTypes(" kp4", after: "Second chapter text.[^2]")

        let rowsAtFlush = GateOrderLog()
        let writerRig = rig.writerRig
        rig.controller.testOrderingSpy = { step in
            if step == "md8FlushApplied" { rowsAtFlush.note((try? writerRig.storedText()) ?? "") }
        }
        hold.release()
        await rig.settleEverything()

        XCTAssertEqual(rowsAtFlush.items.count, 1, "premise: step 8's flush was reached once")
        let atFlush = rowsAtFlush.items.first ?? ""
        XCTAssertTrue(atFlush.contains("kp4"), "the flush did not save the typing made while the job was held")
        XCTAssertTrue(
            atFlush.contains("[^3]: Note three.") && atFlush.contains("[^4]: Note four."),
            "definitions deleted: the typing save sent the Notes definitions the editor removed as deletes")
        XCTAssertEqual(rig.markdownWriter.lastStructuralFlushDisposition, .started, "premise: the flush carried the typing")

        // After the settle's footnote resync (the footnote service owns the Notes rows) and in the editor: each remaining label once.
        let stored = try rig.writerRig.storedText()
        let page = try await rig.pageText()
        for (name, text) in [("rows", stored), ("editor", page)] {
            XCTAssertEqual(text.components(separatedBy: "[^1]: Note one.").count - 1, 1, "duplicate label 1 in the \(name)")
            XCTAssertEqual(text.components(separatedBy: "[^2]: Note two.").count - 1, 1, "duplicate label 2 in the \(name)")
            XCTAssertFalse(text.contains("[^3]: Note three.") || text.contains("[^4]: Note four."), "orphan definitions are still in the \(name)")
            XCTAssertFalse(text.contains("Chapter 3"), "the deleted chapter is still in the \(name)")
            XCTAssertTrue(text.contains("zq7") && text.contains("kp4"), "typing lost from the \(name)")
        }
    }

    /// The same without typing while the job is held: the flush has nothing but the filtered Notes deletes to send.
    func testTheFlushAfterAFootnotedDeleteIsFilteredOnlyWhenNothingWasTyped() async throws {
        rig = try await MarkdownClickRig(markdown: Self.footnotedBook, observesPage: true)
        let chapter3 = try rig.section("Chapter 3")
        let rowsAtFlush = GateOrderLog()
        let writerRig = rig.writerRig
        rig.controller.testOrderingSpy = { step in
            if step == "md8FlushApplied" { rowsAtFlush.note((try? writerRig.storedText()) ?? "") }
        }

        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()

        XCTAssertEqual(
            rig.markdownWriter.lastStructuralFlushDisposition, .stayedRows,
            "the flush was not filtered-only: the removed Notes definitions were sent as deletes")
        XCTAssertEqual(rowsAtFlush.items.count, 1, "premise: step 8's flush was reached once")
        XCTAssertTrue(rowsAtFlush.items.first?.contains("[^3]: Note three.") == true, "definitions deleted")
        XCTAssertFalse(try rig.writerRig.storedText().contains("Chapter 3"), "the deleted chapter is still in the rows")
    }
}
