//
//  SectionReorderPlannerTests.swift
//  final finalTests
//
//  Tier 1: pure array-reordering algorithm coverage for `SectionReorderPlanner`
//  (final final/Services/SectionReorderPlanner.swift), extracted out of
//  ContentView+SectionManagement.swift's `reorderSingleSection`/`reorderSubtree`/
//  `promoteOrphanedChildrenInPlace`. No database, no ContentView, no Task, no polling --
//  mirrors HierarchyEnforcementTests.swift's helper shape (bare `SectionSyncService()`,
//  hand-built `SectionViewModel`s).
//

import Testing
import Foundation
@testable import final_final

@Suite("SectionReorderPlanner — pure array-reordering algorithms")
@MainActor
struct SectionReorderPlannerTests {

    // MARK: - Helpers

    /// Build a SectionViewModel with the given header level, title, and (optionally) parent.
    private func makeSection(
        id: String = UUID().uuidString,
        level: Int,
        title: String,
        parentId: String? = nil
    ) -> SectionViewModel {
        let markdown = String(repeating: "#", count: level) + " " + title
        return SectionViewModel(from: Section(
            id: id,
            projectId: "test",
            parentId: parentId,
            sortOrder: 0,
            headerLevel: level,
            title: title,
            markdownContent: markdown
        ))
    }

    private func titles(_ sections: [SectionViewModel]) -> [String] {
        sections.map(\.title)
    }

    private func levels(_ sections: [SectionViewModel]) -> [Int] {
        sections.map(\.headerLevel)
    }

    // MARK: - Validation guards (4 -- reorderSingleSection has 4 early returns, not the 3 the
    // plan's own prose miscounted: `plan()` absorbs reorderSection's 3 (self-parent,
    // section-not-found, self-drop no-op), and planSingleSection has a 4th of its own
    // (the re-find-after-promotion guard), tested directly below since it's unreachable
    // through `plan()` in normal operation -- `plan()` already validates sectionId is present
    // before ever calling planSingleSection.

    @Test("plan() returns nil when newParentId equals sectionId (self-parent guard)")
    func planRejectsSelfParent() {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 2, title: "B", parentId: a.id)
        let sections = [a, b]
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: a.id, newLevel: 2, newParentId: b.id)

        let result = SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)

        #expect(result == nil)
    }

    @Test("plan() returns nil when sectionId is not found in sections")
    func planRejectsUnknownSectionId() {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let sections = [a]
        let request = SectionReorderRequest(sectionId: "missing-id", targetSectionId: a.id, newLevel: 1, newParentId: nil)

        let result = SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)

        #expect(result == nil)
    }

    @Test("plan() returns nil for a self-drop at the same position (targetSectionId == sectionId)")
    func planRejectsSelfDropNoOp() {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let sections = [a, b]
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: b.id, newLevel: 1, newParentId: nil)

        let result = SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)

        #expect(result == nil)
    }

    // The real 4th early return: planSingleSection's own re-find-after-promotion guard,
    // unreachable through plan() since plan() already guarantees sectionId is present before
    // ever calling planSingleSection -- exercised directly here instead.
    @Test("planSingleSection's own re-find guard returns nil when sectionId is absent")
    func planSingleSectionRejectsWhenSectionIdAbsent() {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let sections = [a]
        let request = SectionReorderRequest(sectionId: "missing-id", targetSectionId: a.id, newLevel: 1, newParentId: nil)

        let result = SectionReorderPlanner.planSingleSection(
            request: request, in: sections, oldLevel: 1, syncService: syncService
        )

        #expect(result == nil)
    }

    // MARK: - Single-section path (6)

    @Test("Basic move: same level, moves after target, updates parentId")
    func singleSectionBasicMove() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let cc = makeSection(level: 1, title: "C")
        let sections = [a, b, cc]
        let request = SectionReorderRequest(sectionId: a.id, targetSectionId: cc.id, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["B", "C", "A"])
        let moved = try #require(result.first { $0.title == "A" })
        #expect(moved.parentId == nil)
        #expect(moved.markdownContent == a.markdownContent, "unchanged level must leave markdown untouched")
    }

    @Test("Level change: headerLevel and markdown are updated when newLevel differs and is > 0")
    func singleSectionLevelChange() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 2, title: "B", parentId: a.id)
        let sections = [a, b]
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: a.id, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))
        let moved = try #require(result.first { $0.title == "B" })

        #expect(moved.headerLevel == 1)
        #expect(moved.markdownContent == syncService.updateHeaderLevel(in: b.markdownContent, to: 1))
    }

    @Test("newLevel == 0 (pseudo-section signal): headerLevel and markdown are left untouched, only parentId updates")
    func singleSectionNewLevelZeroLeavesLevelUntouched() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 2, title: "B", parentId: a.id)
        let cc = makeSection(level: 1, title: "C")
        let sections = [a, b, cc]
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: cc.id, newLevel: 0, newParentId: cc.id)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))
        let moved = try #require(result.first { $0.title == "B" })

        #expect(moved.headerLevel == 2, "newLevel: 0 must not overwrite the section's real header level")
        #expect(moved.markdownContent == b.markdownContent)
        #expect(moved.parentId == cc.id)
    }

    @Test("No target section: inserts at the beginning (index 0)")
    func singleSectionNoTargetInsertsAtStart() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let cc = makeSection(level: 1, title: "C")
        let sections = [a, b, cc]
        let request = SectionReorderRequest(sectionId: cc.id, targetSectionId: nil, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["C", "A", "B"])
    }

    @Test("Move to after the last remaining section inserts at the end of the array")
    func singleSectionInsertAtEnd() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let sections = [a, b]
        // Move A to after B -- B is the only (and therefore last) section once A is removed.
        let request = SectionReorderRequest(sectionId: a.id, targetSectionId: b.id, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["B", "A"])
    }

    @Test("Single-section move promotes orphaned children left behind")
    func singleSectionMovePromotesOrphanedChildren() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "Parent")
        let child = makeSection(level: 2, title: "Child", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [parent, child, target]
        // Move Parent to after Target -- Child is left behind BEFORE where Parent ends up, so
        // it's orphaned and must be promoted to Parent's old level.
        let request = SectionReorderRequest(sectionId: parent.id, targetSectionId: target.id, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))
        let movedChild = try #require(result.first { $0.title == "Child" })

        #expect(movedChild.headerLevel == 1)
        #expect(titles(result) == ["Child", "Target", "Parent"])
    }

    // MARK: - Orphan promotion (3)

    @Test("Orphan promotion: a child that would end up before its parent gets promoted to the parent's old level")
    func orphanPromotionPromotesChildBeforeParent() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "Parent")
        let child = makeSection(level: 2, title: "Child", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [parent, child, target]

        let result = SectionReorderPlanner.promotingOrphanedChildren(
            in: sections, movedSectionId: parent.id, targetSectionId: target.id, oldLevel: 1, syncService: syncService
        )

        let promoted = try #require(result.first { $0.title == "Child" })
        #expect(promoted.headerLevel == 1)
        #expect(
            promoted.markdownContent == syncService.updateHeaderLevel(in: child.markdownContent, to: 1),
            "a promoted child's markdown must actually be rewritten to its new level"
        )
    }

    @Test("Orphan promotion: a child that stays after its parent is left unchanged")
    func orphanPromotionLeavesChildAfterParentUnchanged() throws {
        let syncService = SectionSyncService()
        let target = makeSection(level: 1, title: "Target")
        let parent = makeSection(level: 1, title: "Parent")
        let child = makeSection(level: 2, title: "Child", parentId: parent.id)
        let sections = [target, parent, child]

        // Moving Parent to right after Target keeps Child immediately after Parent -- not orphaned.
        let result = SectionReorderPlanner.promotingOrphanedChildren(
            in: sections, movedSectionId: parent.id, targetSectionId: target.id, oldLevel: 1, syncService: syncService
        )

        let untouched = try #require(result.first { $0.title == "Child" })
        #expect(untouched.headerLevel == 2)
        #expect(
            untouched.markdownContent == child.markdownContent,
            "an unpromoted child's markdown must be byte-identical to its input -- catches an over-eager rewrite"
        )
    }

    @Test("Orphan promotion: with two children, one that ends up before the parent is promoted and one that ends up after is left alone (before/after ordering)")
    func orphanPromotionMixedBeforeAndAfter() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "Parent")
        let childA = makeSection(level: 2, title: "ChildA", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let childB = makeSection(level: 2, title: "ChildB", parentId: parent.id)
        let sections = [parent, childA, target, childB]

        let result = SectionReorderPlanner.promotingOrphanedChildren(
            in: sections, movedSectionId: parent.id, targetSectionId: target.id, oldLevel: 1, syncService: syncService
        )

        let promotedA = try #require(result.first { $0.title == "ChildA" })
        let untouchedB = try #require(result.first { $0.title == "ChildB" })
        #expect(promotedA.headerLevel == 1, "ChildA ends up before Parent's new position -- must be promoted")
        #expect(untouchedB.headerLevel == 2, "ChildB ends up after Parent's new position -- must be left alone")
        #expect(promotedA.markdownContent == syncService.updateHeaderLevel(in: childA.markdownContent, to: 1))
        #expect(
            untouchedB.markdownContent == childB.markdownContent,
            "an unpromoted child's markdown must be byte-identical to its input -- catches an over-eager rewrite"
        )
    }

    // MARK: - Subtree path (7, including the must-fix-2 out-of-document-order case and the
    // must-fix-3 mid-array relocation case)

    @Test("Subtree move: parent + children move together, preserving relative order, with a zero level delta")
    func subtreeBasicMove() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 2, title: "P")
        let c1 = makeSection(level: 3, title: "C1", parentId: pp.id)
        let c2 = makeSection(level: 3, title: "C2", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, pp, c1, c2]
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id, c2.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["Target", "P", "C1", "C2"])
        #expect(levels(result) == [1, 2, 3, 3])
    }

    @Test("Subtree move: negative level delta (promotion) shifts every moved section's level down by the same amount")
    func subtreePromotionDelta() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 3, title: "P")
        let c1 = makeSection(level: 4, title: "C1", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, pp, c1]
        // oldLevel = 3, newLevel = 1 -> delta = -2
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(levels(result) == [1, 1, 2])
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })
        #expect(movedParent.markdownContent == syncService.updateHeaderLevel(in: pp.markdownContent, to: 1))
        #expect(movedChild.markdownContent == syncService.updateHeaderLevel(in: c1.markdownContent, to: 2))
    }

    @Test("Subtree move: positive level delta (demotion) shifts every moved section's level up by the same amount")
    func subtreeDemotionDelta() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 1, title: "P")
        let c1 = makeSection(level: 2, title: "C1", parentId: pp.id)
        let target = makeSection(level: 2, title: "Target")
        let sections = [target, pp, c1]
        // oldLevel = 1, newLevel = 3 -> delta = +2
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 3, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(levels(result) == [2, 3, 4])
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })
        #expect(movedParent.markdownContent == syncService.updateHeaderLevel(in: pp.markdownContent, to: 3))
        #expect(movedChild.markdownContent == syncService.updateHeaderLevel(in: c1.markdownContent, to: 4))
    }

    @Test("Subtree move: mid-array relocation with content on both sides exercises the removal/reinsertion index math (must-fix 3)")
    func subtreeMidArrayRelocationWithContentOnBothSides() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 2, title: "P")
        let c1 = makeSection(level: 3, title: "C1", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        let tail = makeSection(level: 1, title: "Tail")
        // The moved subtree (P, C1) originates BEFORE the target, and other content (Tail)
        // exists after the target -- unlike the other subtree tests, where the target is
        // either the very last element or the moved block is already adjacent to it.
        let sections = [pp, c1, target, tail]
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["Target", "P", "C1", "Tail"])
    }

    @Test("Subtree move: a childId not present in sections is tolerated and silently skipped")
    func subtreeMissingChildIdTolerated() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 1, title: "P")
        let c1 = makeSection(level: 2, title: "C1", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, pp, c1]
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id, "does-not-exist"]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(titles(result) == ["Target", "P", "C1"])
    }

    @Test("Subtree move: newParentId is applied only to the moved parent section, not to its children (children's parentId is recalculated elsewhere)")
    func subtreeOnlyParentGetsNewParentId() throws {
        let syncService = SectionSyncService()
        let oldParent = makeSection(level: 1, title: "OldParent")
        let pp = makeSection(level: 2, title: "P", parentId: oldParent.id)
        let c1 = makeSection(level: 3, title: "C1", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [oldParent, pp, c1, target]
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [c1.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })

        #expect(movedParent.parentId == target.id)
        #expect(movedChild.parentId == pp.id, "children keep their existing parentId here -- recalculation happens outside this function")
        #expect(titles(result) == ["OldParent", "Target", "P", "C1"])
    }

    @Test("Subtree move: childIds arriving out of document order are reinserted in REQUEST order, not original document order (must-fix 2 -- locks current behavior, does not change it)")
    func subtreeChildIdsOutOfDocumentOrderFollowRequestOrder() throws {
        let syncService = SectionSyncService()
        let pp = makeSection(level: 1, title: "P")
        let a = makeSection(level: 2, title: "A", parentId: pp.id)
        let b = makeSection(level: 2, title: "B", parentId: pp.id)
        let target = makeSection(level: 1, title: "Target")
        // Document order is P, A, B, Target -- A precedes B in the document.
        let sections = [pp, a, b, target]
        // childIds lists B before A: the REVERSE of document order.
        let request = SectionReorderRequest(
            sectionId: pp.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [b.id, a.id]
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        // sectionsToMove is built in allIdsToMove (request) order while indicesToRemove is
        // sorted by document index -- the reinserted block follows REQUEST order (P, B, A),
        // not document order (P, A, B). This is the real, previously-untested branch must-fix 2
        // flags: whatever this produces is locked in here, not asserted as correct or incorrect.
        #expect(titles(result) == ["Target", "P", "B", "A"])
    }

    // MARK: - plan() routing (isSubtreeDrag + empty childIds falls through to single-section)

    @Test("plan(): isSubtreeDrag with empty childIds routes to the single-section path, not the subtree path")
    func planRoutesEmptyChildIdsSubtreeDragToSingleSectionPath() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "Parent")
        let child = makeSection(level: 2, title: "Child", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [parent, child, target]
        // isSubtreeDrag: true but childIds is empty -- reorderSection's original branch
        // condition is `isSubtreeDrag && !childIds.isEmpty`, so this must take the
        // single-section path (which promotes the orphaned child), not the subtree path
        // (which would leave it behind with its old level untouched, since childIds is empty
        // and nothing would be collected to move alongside the parent).
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 1, newParentId: nil,
            isSubtreeDrag: true, childIds: []
        )

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))
        let movedChild = try #require(result.first { $0.title == "Child" })

        #expect(movedChild.headerLevel == 1, "empty childIds must route through the single-section path, which promotes orphaned children")
    }

    // MARK: - Cross-check tying a no-op drop to dispatchSectionReorder's existing short-circuit

    @Test("Cross-check: a no-op drop's planned order is recognized as unchanged by ContentView.sectionOrderUnchanged, the same check dispatchSectionReorder uses to skip dispatch entirely")
    func noOpPlanIsRecognizedByDispatchsExistingShortCircuit() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let sections = [a, b]
        // B already directly follows A -- dropping B "after A" again is a structural no-op.
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: a.id, newLevel: 1, newParentId: nil)

        let result = try #require(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService))

        #expect(ContentView.sectionOrderUnchanged(result, from: sections))
    }
}
