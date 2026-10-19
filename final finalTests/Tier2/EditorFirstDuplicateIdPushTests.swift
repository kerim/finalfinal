//
//  EditorFirstDuplicateIdPushTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 1, round 1g-C, code review A2): the settle of an editor-first Duplicate Section puts the
//  DATABASE's block ids onto the editor (`pushBlockIds`) when the job reported that the editor's copies and the rows it inserted
//  differ, so both sides agree afterwards; and does nothing of the kind when they agree. A duplicate whose copies match the rows
//  must not pay for an id push, which re-baselines block-sync (`resetAndSnapshot`).
//
//  Driven with a REAL `BlockSyncService` and `DocumentWriter` and a scripted editor (`EditorFirstRig`); the push itself is the rig's
//  `testPushBlockIdsHook` (counted in `pushBlockIdsCalls`). The matcher is tested in Tier1 (DuplicateSectionsEditorCopiesTests,
//  DuplicateSectionsRealReplyTests).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first duplicate: the database's ids go to the editor when the copies differ (round 1g-C, A2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct EditorFirstDuplicateIdPushTests: QuickUndoFixtures {

    private func duplicate(_ rig: EditorFirstRig, _ title: String) async throws {
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading(title).id)
        #expect(outcome == .performed, "the duplicate of \(title) ended \(outcome)")
        #expect(await rig.waitUntilSettled(), "the duplicate of \(title) did not settle")
    }

    // A duplicate whose copies match the rows pushes no ids; one whose copies differ pushes them once, in its settle.
    @Test func testIdsAreOnlyPushedWhenTheEditorsCopiesDifferFromTheRows() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)

        try await duplicate(rig, "Section A")
        #expect(rig.pushBlockIdsCalls == 0, "a duplicate whose copies match the rows pushed block ids anyway (\(rig.pushBlockIdsCalls))")
        #expect(try rig.blocks().contains { $0.textContent == "Section A copy" }, "the first duplicate did not apply")

        rig.duplicateReplyAddsCopyWithoutRow = true
        try await duplicate(rig, "Section B")
        #expect(try rig.blocks().contains { $0.textContent == "Section B copy" }, "the second duplicate did not apply")
        #expect(
            rig.pushBlockIdsCalls == 1,
            "the copies differed from the rows but the settle pushed the database's block ids \(rig.pushBlockIdsCalls) time(s), not once")

        try await duplicate(rig, "Section C")
        #expect(rig.pushBlockIdsCalls == 1, "a later duplicate whose copies match pushed ids again (\(rig.pushBlockIdsCalls))")
    }
}
