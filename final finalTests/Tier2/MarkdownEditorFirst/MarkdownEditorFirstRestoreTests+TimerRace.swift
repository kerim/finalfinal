//
//  MarkdownEditorFirstRestoreTests+TimerRace.swift
//  final finalTests
//
//  t-f1a22aa7 (Phase 4c, job 1: the footnote timer against a Markdown section command), round 2b: the Version History restore's rig test.
//  An extension of the class in MarkdownEditorFirstRestoreTests.swift (`startRig`, `saveVersion`, `typeAndSave`, `restoreProject` and the
//  bounded waits of +Support); the shared setup (the armed footnote service, the parked settle, the page's call log, the setup steps) is in
//  MarkdownFootnoteTimerRaceTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  R3 is the Delete test's twin for Restore Entire Project. The restore's settle is the one that replaces the document text, so before
//  its resyncs it reads the editor's own text; the timer must still stand aside while that settle is parked.
//
//  Break patches (docs/architecture/write-queue-plan/phase4c/footnote-timer/break-patches/) and what the test shows under them:
//
//   R3   BP-A (burst writes while the command is unfinished)   FAILS: "the timer's renumber reached the page outside the settle flag:
//                                                              [renumber, set:<op>, set:null]"
//        BP-C (hook not wired)                                 FAILS: "the burst never saw the command's unfinished work (hook not wired)"
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstRestoreTests {

    // MARK: - R3

    // CLAIM: a version of the two-footnote book is saved, the document is changed after it, and Restore Entire Project puts the version
    // back; the settle is parked. The user types ` see[^9]` at the end of Chapter 3 (the label 9 becomes 3). The app's check arms a burst
    // and the timer comes due while the settle is parked: it must stand aside, so the page's only renumber is the settle's, between the
    // flag's set and clear, and the new reference reads [^3] afterwards.
    func testRestoreTheTimerDueDuringTheHeldSettleRenumbersOnlyInsideTheSettleFlag() async throws {
        try await startRig(Self.footnotedBook)
        let armed = try await rig.armTimerRace()
        let hold = TimerRaceSettleHold(controller: rig.controller)
        defer {
            armed.stop()
            hold.open()
        }
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")

        let outcome = try await restoreProject(from: version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        let held = await hold.waitUntilReached(in: rig)
        XCTAssertTrue(held, "the settle never reached its hold")
        let restored = try await pageText()
        XCTAssertFalse(restored.contains("EDITED"), "premise: the restore put the version's text on the page")
        try await rig.typeAndWaitForRecord(" see[^9]", after: "Third chapter text.[^2]")

        await armed.armTheBurstAndWaitForTheTimer()
        hold.open()
        try await settleAll()

        try await armed.assertTheRenumberCameInsideTheFlag()
        let page = try await pageText()
        XCTAssertTrue(page.contains("see[^3]"), "the new reference was not renumbered to 3: \(page)")
        XCTAssertEqual(rig.footnotes.lastKnownRefs, ["1", "2", "3"], "the settle's resync did not commit the renumbered references")
    }
}
