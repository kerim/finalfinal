//
//  BlockSyncGenerationGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for BlockSyncService.shouldAbandonForGenerationChange — the mid-flight
//  guard that abandons a poll cycle's batch when content was wholesale replaced
//  (mode toggle, zoom, bibliography/notes rebuild, project switch) since the
//  cycle began. Applies in force mode too: `force` bypasses the contentState
//  *precondition* at cycle start, never mid-flight invalidation.
//

import Testing
@testable import final_final

@Suite("BlockSync generation guard — Tier 1: Silent Killers")
struct BlockSyncGenerationGuardTests {

    @Test("Does NOT abandon when generation is unchanged")
    func doesNotAbandonWhenUnchanged() {
        let abandon = BlockSyncService.shouldAbandonForGenerationChange(
            currentGeneration: 4,
            generationAtPollStart: 4,
            wasWiredAtPollStart: true
        )
        #expect(!abandon)
    }

    @Test("Abandons when generation changed (content was wholesale replaced mid-flight)")
    func abandonsWhenGenerationChanged() {
        let abandon = BlockSyncService.shouldAbandonForGenerationChange(
            currentGeneration: 5,
            generationAtPollStart: 4,
            wasWiredAtPollStart: true
        )
        #expect(abandon)
    }

    @Test("Does NOT abandon when editorState was NEVER wired (nil at both capture and check) — regression guard")
    func doesNotAbandonWhenNeverWired() {
        // A naive unconditional (currentGeneration != generationAtPollStart) check
        // would treat `nil != 0` as true and reject every forced flush that has no
        // editorState wired at all — breaking, e.g., ZoomWordCountSyncTests, whose
        // BlockSyncService stack never assigns `editorState`. `wasWiredAtPollStart:
        // false` means editorState was already nil at capture time too, so nil now
        // isn't a change — it's the legitimate "no generation tracking available"
        // case, not staleness.
        let abandon = BlockSyncService.shouldAbandonForGenerationChange(
            currentGeneration: nil,
            generationAtPollStart: 0,
            wasWiredAtPollStart: false
        )
        #expect(!abandon)
    }

    @Test("Abandons when editorState was wired at capture but has since gone nil (torn down mid-poll)")
    func abandonsWhenTornDownMidPoll() {
        // Opposite direction from the never-wired case above: editorState WAS present
        // when generationAtPollStart was captured (wasWiredAtPollStart: true) but is
        // nil by the time this check runs — e.g. EditorViewState deallocated mid-poll
        // during a project switch. A live editorState disappearing mid-flight is itself
        // evidence of a wholesale teardown, so this must abandon rather than silently
        // proceed to write a stale batch against database/projectId locals captured
        // before the switch. Regression guard: a naive nil-safe predicate that only
        // checks `currentGeneration == nil` (ignoring history) would fail-open here.
        let abandon = BlockSyncService.shouldAbandonForGenerationChange(
            currentGeneration: nil,
            generationAtPollStart: 4,
            wasWiredAtPollStart: true
        )
        #expect(abandon)
    }

    @Test("Abandons regardless of direction (generation decreasing counts as changed too)")
    func abandonsOnAnyDifference() {
        // The predicate only checks equality, not monotonic increase — a defensive
        // property test in case future callers ever reset contentGeneration.
        let abandon = BlockSyncService.shouldAbandonForGenerationChange(
            currentGeneration: 2,
            generationAtPollStart: 7,
            wasWiredAtPollStart: true
        )
        #expect(abandon)
    }
}
