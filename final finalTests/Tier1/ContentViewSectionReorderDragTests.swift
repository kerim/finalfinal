//
//  ContentViewSectionReorderDragTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, plan U10 and review items G11 and C4): the START and the END of a sidebar card drag, and the drop's own
//  short-circuits. The drag start used to set a drag-time `contentState` (a case that no longer exists), and that write bumped
//  `contentGeneration`, which discards a typing batch a routine poll had already fetched (finding M1: type, then drag straight away, and
//  the typing is lost). The editor-first reorder it precedes needs no such state, so the drag start now only cancels the debounced
//  section sync, and the drag end and every drop exit that runs no reorder give it back (G11). A drop made while another structural
//  command holds the gate or waits for it is not judged against the sidebar's list, which is the one from before that command (C4).
//  An extension of `ContentViewSectionReorderTests` (its `makeFixture()` wires a bare `ContentView`), in its own file for SwiftLint's
//  file length.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

extension ContentViewSectionReorderTests {

    // U10: pressing and dragging a card leaves the content state alone, and does not touch the generation counter.
    @Test("dragStartLeavesContentStateAlone")
    func dragStartLeavesContentStateAlone() throws {
        let fixture = try makeFixture()
        let editorState = fixture.view.editorState
        #expect(editorState.contentState == .idle, "precondition: the editor is idle before the drag")
        let generation = editorState.contentGeneration

        fixture.view.handleSectionDragStarted()

        #expect(editorState.contentState == .idle, "the drag start set the content state: \(editorState.contentState)")
        #expect(editorState.contentGeneration == generation, "the drag start bumped contentGeneration and could discard a fetched batch")
    }

    // G11: the drag start cancelled the debounced section sync (the one the user's last typing had scheduled). When the drag ends the sync is
    // scheduled again for the editor's text, so a drag that is abandoned (or a drop that does nothing) does not leave the `section` table
    // without it. `editorState.content` is not what the service last synced, so a re-armed sync is pending.
    @Test("dragEndGivesBackTheSectionSyncTheDragStartCancelled")
    func dragEndGivesBackTheSectionSyncTheDragStartCancelled() throws {
        let fixture = try makeFixture()
        let view = fixture.view
        view.handleSectionDragStarted()
        #expect(!view.sectionSyncService.isSyncPending, "precondition: nothing is pending after the drag start")

        view.handleSectionDragEnded()

        #expect(view.sectionSyncService.isSyncPending, "the section sync was not scheduled again when the drag ended")
    }

    // G11: a drop that runs no reorder gives the sync back too. A card dropped onto itself is a benign no-op (no toast).
    @Test("aDropThatChangesNothingGivesBackTheSectionSync")
    func aDropThatChangesNothingGivesBackTheSectionSync() throws {
        let fixture = try makeFixture()
        let view = fixture.view
        let card = try #require(view.editorState.sections.first { $0.title == "Methodology" })
        view.handleSectionDragStarted()
        #expect(!view.sectionSyncService.isSyncPending, "precondition: nothing is pending after the drag start")

        view.reorderSection(SectionReorderRequest(
            sectionId: card.id, targetSectionId: card.id, newLevel: card.headerLevel, newParentId: card.parentId))

        #expect(view.sectionSyncService.isSyncPending, "a drop that did nothing left the section sync cancelled")
    }

    // G11: and a drop the planner rejects (a card the list does not hold) gives it back as well, after its toast.
    @Test("aDropTheListCannotPlanGivesBackTheSectionSync")
    func aDropTheListCannotPlanGivesBackTheSectionSync() throws {
        let fixture = try makeFixture()
        let view = fixture.view
        let target = try #require(view.editorState.sections.first)
        view.handleSectionDragStarted()
        #expect(!view.sectionSyncService.isSyncPending, "precondition: nothing is pending after the drag start")

        view.reorderSection(SectionReorderRequest(sectionId: "no-such-card", targetSectionId: target.id, newLevel: 1, newParentId: nil))

        #expect(view.sectionSyncService.isSyncPending, "a drop that failed to plan left the section sync cancelled")
    }

    // C4 (EVERYDAY): a second drag made while an earlier command still holds the structural gate. The sidebar's list is then the one from
    // BEFORE that command, so a drop that looks like "already in place" there (Results and Discussion right after Methodology) may be a
    // real move once the command has finished (it had moved Results and Discussion away). The drop-time check must not swallow it: the
    // request goes on to the controller, which plans it again under the gate on the list as it is then and carries it out. The old
    // whole-document sequence is what runs here (this bare view has no editor), and its `beginStructuralOp` call is how the test sees that
    // the reorder started.
    @Test("aDropWhileTheGateIsBusyIsNotSwallowedByTheDropTimeShortCircuit")
    func aDropWhileTheGateIsBusyIsNotSwallowedByTheDropTimeShortCircuit() async throws {
        let fixture = try makeFixture()
        let view = fixture.view
        let state = view.editorState
        let stale = state.sections
        let request = try makeRequest(sections: stale, moveTitle: "Results and Discussion", afterTitle: "Methodology")
        var beginCount = 0
        view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") { beginCount += 1 }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let gate = state.structuralGate
        #expect(await gate.acquire() == .granted, "precondition: the test holds the gate, like an earlier command that is still running")
        #expect(view.structuralGateIsBusy, "precondition: the view sees the busy gate")
        view.reorderSection(request)   // looks like "already in place" on the stale list
        for _ in 0..<5 { await Task.yield() }
        // The earlier command finishes: it had swapped the two cards, so the request is a real move now.
        state.sections = try swapSections(stale, "Methodology", "Results and Discussion")
        gate.release()

        var started = false
        for _ in 0..<50 {
            if beginCount >= 1 { started = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(started, "the drop made while the gate was busy was swallowed: the reorder never started")
    }
}
