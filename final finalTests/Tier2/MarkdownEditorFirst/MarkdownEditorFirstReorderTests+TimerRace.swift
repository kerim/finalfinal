//
//  MarkdownEditorFirstReorderTests+TimerRace.swift
//  final finalTests
//
//  t-f1a22aa7 (Phase 4c, job 1: the footnote timer against a Markdown section command), round 2b: the drag's two rig tests. An extension
//  of the class in MarkdownEditorFirstReorderTests.swift (the nine-footnote book `makePrimedRig` builds, and `drop`); the shared setup
//  (the armed footnote service, the parked settle, the page's call log, the setup steps) is in MarkdownFootnoteTimerRaceTests.swift.
//  Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  THE DRAG IS THE CASE THAT SHOWED THE RACE. A move changes the ORDER of the references but not which labels there are, so the renumber
//  the settle's footnote resync makes ends in the very list the footnote service last committed, and `performFootnoteUpdate` skips it at
//  its `lastRenumberedHash` guard unless the hash is forgotten. Since t-f1a22aa7 the hash is forgotten INSIDE the footnote resync
//  (`resyncNow(forgetCommittedHash:)`, FIX-G, asked for by `resyncAfterEditorFirstDelete(forgetsCommittedNotes:)`, FIX-E), after the
//  resync's idle wait and with nothing between the forget and the write. The two tests below pin the two things that change with that:
//
//   R4   the timer comes due while the drag's settle is parked: it must stand aside, so the one renumber the page receives is the
//        settle's, inside the flag, and the Notes come out SORTED (a timer renumber outside the flag only relabels them). The user types
//        `[^99]` first, so the label list changes and the timer's run would get past the hash guard (a plain drag's would not).
//   R4b  a footnote inserted with /footnote while the drag's settle is parked: the immediate insertion commits a hash of its own without
//        renumbering, so a forget made EARLIER (the old site, at the start of the settle) is undone before the resync, which then skips
//        at the guard and leaves the references out of reading order. The forget at the resync's own start survives.
//
//  Break patches (docs/architecture/write-queue-plan/phase4c/footnote-timer/break-patches/) and what each test shows under them:
//
//   R4   BP-A (burst writes while the command is unfinished)   FAILS: "Notes region not sorted: [1, 2, 3, 8, 9, 10, 5, 6, 7]"
//                                                              (and "the timer's renumber reached the page outside the settle flag")
//        BP-C (hook not wired)                                 FAILS: "the burst never saw the command's unfinished work (hook not wired)"
//   R4b  BP-E (the old forget site back)                       FAILS: "references out of reading order after /footnote during the drag's
//                                                              settle: [1, 2, 3, 4, 8, 9, 10, 5, 6, 7]"
//        BP-G (the forget inside `resyncNow` removed)          FAILS: the same message
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstReorderTests {

    private static var oneToTen: [String] { (1...10).map(String.init) }

    /// The page's Notes labels after a renumber of the nine-footnote book with one footnote added in Chapter One: label 4 has no
    /// definition on the page until the Notes region is pushed from the rows (there is no ContentView in the rig to push it).
    private static var notesLabelsWithoutTheNewOne: [String] { ["1", "2", "3", "5", "6", "7", "8", "9", "10"] }

    private func shown(_ labels: [String]) -> String { "[\(labels.joined(separator: ", "))]" }

    // MARK: - R4

    // CLAIM: Chapter Three is dragged above Chapter Two (the page reads 1-3, 7-9, 4-6), the settle is parked, and the user types `[^99]` at
    // the end of Chapter One's text. The app's check arms a burst; the timer comes due while the settle is parked and stands aside. After
    // the settle: the references read 1 to 10 in reading order (99 became 4), the page's Notes are SORTED (every definition once, labels
    // ascending, the new reference having none yet), the Notes rows are 1 to 10, and the page's only renumber came between the flag's
    // set and clear.
    func testDragTimerDueDuringTheHeldSettleLeavesTheNotesSorted() async throws {
        let rig = try await makePrimedRig()
        let probe = try await rig.armTimerRace()
        let hold = TimerRaceSettleHold(controller: rig.controller)
        defer {
            probe.stop()
            hold.open()
            rig.controller.testEFSettleHold = nil
        }

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        let held = await hold.waitUntilReached(in: rig)
        XCTAssertTrue(held, "the settle never reached its hold")
        try await rig.typeAndWaitForRecord("[^99]", after: "Claim 3 rests on a source[^3].")

        await probe.armTheBurstAndWaitForTheTimer()
        hold.open()
        await rig.settleEverything()

        let calls = try await probe.callsOnceTheFlagIsCleared()
        let page = try await rig.pageText()
        let refs = FootnoteSyncService.extractFootnoteRefs(from: page)
        XCTAssertEqual(refs, Self.oneToTen, "footnote references out of order: \(shown(refs)) (wanted 1 to 10 in reading order)")
        let pageLabels = TimerRaceProbe.definitionLabels(in: page)
        XCTAssertEqual(pageLabels, Self.notesLabelsWithoutTheNewOne, "Notes region not sorted: \(shown(pageLabels))")
        let rowLabels = try rig.notesRowLabels()
        XCTAssertEqual(rowLabels, Self.oneToTen, "the Notes rows are not 1 to 10: \(shown(rowLabels))")
        XCTAssertEqual(calls, ["set:<op>", "renumber", "set:null"], "\(TimerRaceProbe.outsideTheFlag): \(calls)")
        XCTAssertFalse(rig.footnotes.testHasPendingUpdate, "the settle's resync left the burst that stood aside waiting")
    }

    // MARK: - R4b

    // CLAIM (finding F1): Chapter Three is dragged above Chapter Two and the settle is parked. The user inserts a footnote with /footnote
    // at the end of Chapter One's text: the page shifts its own labels at once (the new one is 4, the moved chapter's become 8 to 10,
    // the other's 5 to 7), and the immediate insertion commits (`beginImmediateInsertion` and `commitImmediateInsertion`, the sequence of
    // `handleFootnoteInsertedImmediate`), which writes the service's committed hash WITHOUT renumbering. The settle's footnote resync must
    // still renumber: afterwards the references read 1 to 10 in reading order, the page's Notes are sorted and the Notes rows are 1 to
    // 10. No burst is armed here: `beginImmediateInsertion` cancels any waiting one, and the claim is about the resync meeting the hash.
    func testDragThenSlashFootnoteDuringTheHeldSettleRenumbersAndSorts() async throws {
        let rig = try await makePrimedRig()
        let probe = try await rig.armTimerRace()
        let hold = TimerRaceSettleHold(controller: rig.controller)
        defer {
            probe.stop()
            hold.open()
            rig.controller.testEFSettleHold = nil
        }

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        let held = await hold.waitUntilReached(in: rig)
        XCTAssertTrue(held, "the settle never reached its hold")

        let label = try await rig.insertFootnote(after: "Claim 3 rests on a source[^3].")
        XCTAssertEqual(label, "4", "premise: the new footnote is the fourth in reading order")
        let shifted = ["1", "2", "3", "4", "8", "9", "10", "5", "6", "7"]
        let reported = await rig.waitUntil { FootnoteSyncService.extractFootnoteRefs(from: rig.editorState.content) == shifted }
        XCTAssertTrue(reported, "premise: the content record has the page's shifted references")
        await rig.commitImmediateInsertion(label: label)

        hold.open()
        await rig.settleEverything()

        _ = try await probe.callsOnceTheFlagIsCleared()
        let page = try await rig.pageText()
        let refs = FootnoteSyncService.extractFootnoteRefs(from: page)
        XCTAssertEqual(
            refs, Self.oneToTen, "references out of reading order after /footnote during the drag's settle: \(shown(refs))")
        let pageLabels = TimerRaceProbe.definitionLabels(in: page)
        XCTAssertEqual(pageLabels, Self.notesLabelsWithoutTheNewOne, "Notes region not sorted: \(shown(pageLabels))")
        let rowLabels = try rig.notesRowLabels()
        XCTAssertEqual(rowLabels, Self.oneToTen, "the Notes rows are not 1 to 10: \(shown(rowLabels))")
    }
}
