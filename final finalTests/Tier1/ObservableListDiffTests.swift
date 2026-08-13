//
//  ObservableListDiffTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Guards the id-based in-place merge for `EditorViewState.sections` and
//  `.annotations`. Wholesale array replacement hands each sidebar card a new
//  view-model reference every database tick, forcing that card's observation
//  tracking to tear down and reinstall — 48% of main-thread busy time in the
//  2026-08-10 Instruments trace. These tests assert object identity survives
//  a re-fetch. Test 9 pins the subtree walk that the drag payload depends on.
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite("Observable List Diff — Tier 1: Silent Killers")
struct ObservableListDiffTests {

    private func heading(_ id: String, _ order: Double, level: Int = 1,
                         text: String = "Title") -> Block {
        Block(id: id, projectId: "p", sortOrder: order, blockType: .heading,
              textContent: text,
              markdownFragment: String(repeating: "#", count: level) + " " + text,
              headingLevel: level)
    }

    private func counts(_ pairs: [String: Int]) -> [String: ProjectDatabase.HeadingWordCounts] {
        pairs.mapValues { .init(sectionOnly: $0, aggregate: $0) }
    }

    @Test func sectionMergeKeepsIdentityWhenNothingChanged() {
        var vms: [SectionViewModel] = []
        let blocks = [heading("a", 0), heading("b", 1), heading("c", 2)]
        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: counts(["a": 1, "b": 2, "c": 3]))
        let before = vms.map { ObjectIdentifier($0) }

        let changed = EditorViewState.mergeSections(into: &vms, from: blocks,
                                                   counts: counts(["a": 1, "b": 2, "c": 3]))
        #expect(changed == false)
        #expect(vms.map { ObjectIdentifier($0) } == before)
    }

    @Test func sectionMergeUpdatesWordCountInPlace() {
        var vms: [SectionViewModel] = []
        let blocks = [heading("a", 0), heading("b", 1)]
        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: counts(["a": 1, "b": 2]))
        let before = vms.map { ObjectIdentifier($0) }

        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: counts(["a": 9, "b": 2]))
        #expect(vms.map { ObjectIdentifier($0) } == before)
        #expect(vms[0].wordCount == 9)
        #expect(vms[1].wordCount == 2)
    }

    // apply() must not clobber counts: a merge with no counts entry retains
    // the previous value rather than resetting it to the initializer's 0.
    @Test func sectionMergeRetainsWordCountWhenCountsMissing() {
        var vms: [SectionViewModel] = []
        let blocks = [heading("a", 0)]
        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: counts(["a": 42]))
        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: [:])
        #expect(vms[0].wordCount == 42)
    }

    @Test func sectionMergeAppliesInsertRemoveReorder() {
        var vms: [SectionViewModel] = []
        _ = EditorViewState.mergeSections(into: &vms, from: [heading("a", 0), heading("b", 1)],
                                          counts: counts([:]))
        let keptB = vms[1]

        let changed = EditorViewState.mergeSections(
            into: &vms,
            from: [heading("b", 0), heading("c", 1)],
            counts: counts([:]))
        #expect(changed == true)
        #expect(vms.map(\.id) == ["b", "c"])
        #expect(vms[0] === keptB)
    }

    @Test func sectionMergeUpdatesTitleAndLevelInPlace() {
        var vms: [SectionViewModel] = []
        _ = EditorViewState.mergeSections(into: &vms, from: [heading("a", 0, level: 1, text: "One")],
                                          counts: counts([:]))
        let kept = vms[0]

        _ = EditorViewState.mergeSections(into: &vms, from: [heading("a", 0, level: 2, text: "Two")],
                                          counts: counts([:]))
        #expect(vms[0] === kept)
        #expect(vms[0].headerLevel == 2)
        #expect(vms[0].title.contains("Two"))
    }

    @Test func parentRecalculationKeepsIdentity() {
        let state = EditorViewState()
        var vms: [SectionViewModel] = []
        _ = EditorViewState.mergeSections(
            into: &vms,
            from: [heading("a", 0, level: 1), heading("b", 1, level: 2)],
            counts: counts([:]))
        state.sections = vms
        let before = state.sections.map { ObjectIdentifier($0) }

        state.recalculateParentRelationships()
        #expect(state.sections.map { ObjectIdentifier($0) } == before)
        #expect(state.sections[1].parentId == "a")
    }

    private func annotation(_ id: String, text: String = "note",
                            offset: Int = 0, done: Bool = false) -> Annotation {
        Annotation(id: id, contentId: "c", sectionId: nil, type: .comment,
                   text: text, isCompleted: done, charOffset: offset,
                   highlightStart: nil, highlightEnd: nil)
    }

    @Test func annotationMergeKeepsIdentityAndAppliesUpdates() {
        var vms: [AnnotationViewModel] = []
        let incoming = [annotation("x", text: "before", offset: 3), annotation("y")]
        _ = EditorViewState.mergeAnnotations(into: &vms, from: incoming)
        let before = vms.map { ObjectIdentifier($0) }

        #expect(EditorViewState.mergeAnnotations(into: &vms, from: incoming) == false)
        #expect(vms.map { ObjectIdentifier($0) } == before)

        _ = EditorViewState.mergeAnnotations(
            into: &vms,
            from: [annotation("x", text: "after", offset: 7, done: true), annotation("y")])
        #expect(vms.map { ObjectIdentifier($0) } == before)
        #expect(vms[0].text == "after")
        #expect(vms[0].charOffset == 7)
        #expect(vms[0].isCompleted == true)
    }

    @Test func annotationMergeAppliesInsertRemove() {
        var vms: [AnnotationViewModel] = []
        _ = EditorViewState.mergeAnnotations(into: &vms, from: [annotation("x"), annotation("y")])
        let keptY = vms[1]

        let changed = EditorViewState.mergeAnnotations(into: &vms, from: [annotation("y"), annotation("z")])
        #expect(changed == true)
        #expect(vms.map(\.id) == ["y", "z"])
        #expect(vms[0] === keptY)
    }

    // Drag payload: the subtree walk fix 3 extracts must be behaviour-identical.
    // Collect strictly-deeper sections after the root; stop at the first
    // section at the same or shallower level; unknown root yields [].
    @Test func subtreeIdsMatchesLevelWalk() {
        var vms: [SectionViewModel] = []
        _ = EditorViewState.mergeSections(into: &vms, from: [
            heading("h1", 0, level: 1),
            heading("h2a", 1, level: 2),
            heading("h3", 2, level: 3),
            heading("h2b", 3, level: 2),
            heading("next1", 4, level: 1),
            heading("deep", 5, level: 3)
        ], counts: counts([:]))

        #expect(OutlineSidebar.subtreeIds(rootId: "h1", in: vms) == ["h2a", "h3", "h2b"])
        #expect(OutlineSidebar.subtreeIds(rootId: "h2a", in: vms) == ["h3"])
        #expect(OutlineSidebar.subtreeIds(rootId: "h2b", in: vms) == [])
        #expect(OutlineSidebar.subtreeIds(rootId: "next1", in: vms) == ["deep"])
        #expect(OutlineSidebar.subtreeIds(rootId: "nope", in: vms) == [])
    }

    // The central claim of this whole fix: a no-op merge (identical blocks/counts) followed
    // by the per-tick parent recalculation must not fire any @Observable notification on the
    // sections it merged into. Before must-fixes 1 and 3 this was demonstrably false --
    // `inout` access to `state.sections` itself fired unconditionally, and `apply()` wrote
    // `parentId` on every call even though `recalculateParentRelationships()` immediately
    // overwrites it anyway. This test exercises the same merge-into-a-local-copy pattern the
    // production call sites use (see `EditorViewState.startObserving`), not a direct
    // `&state.sections` pass, or it would not actually catch a regression of must-fix 1.
    @Test func noOpMergeThenParentRecalcFiresNoObservation() {
        let state = EditorViewState()
        var vms: [SectionViewModel] = []
        let blocks = [heading("a", 0, level: 1), heading("b", 1, level: 2)]
        _ = EditorViewState.mergeSections(into: &vms, from: blocks, counts: counts(["a": 1, "b": 2]))
        state.sections = vms
        state.recalculateParentRelationships()

        var fired = false
        withObservationTracking {
            for section in state.sections {
                _ = section.title
                _ = section.headerLevel
                _ = section.parentId
                _ = section.markdownContent
                _ = section.status
                _ = section.wordCount
            }
        } onChange: {
            fired = true
        }

        // Re-run the identical merge into a local copy, then the same parent recalculation
        // the production observation loop performs on every tick -- neither should touch
        // anything the tracking above observed.
        var reMerged = state.sections
        let changed = EditorViewState.mergeSections(into: &reMerged, from: blocks, counts: counts(["a": 1, "b": 2]))
        if changed { state.sections = reMerged }
        state.recalculateParentRelationships()

        #expect(changed == false)
        #expect(fired == false)
    }
}
