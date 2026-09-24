//
//  SectionReorderPlannerSubtreeTests.swift
//  final finalTests
//
//  Split out of SectionReorderPlannerTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full
//  SectionReorderPlanner background (pure array-reordering, no database, no ContentView). This
//  file covers the subtree-move path (parent + children moving together, level-delta shifts,
//  out-of-document-order childIds, mid-array relocation index math), plan()'s routing for an
//  empty-childIds subtree drag, and the no-op-drop cross-check against
//  ContentView.sectionOrderUnchanged -- using the shared `makeSection`/`titles`/`levels`/
//  `planned`/`isFailed`/`isNoOp` helpers defined in SectionReorderPlannerTests.swift.
//

import Testing
import Foundation
@testable import final_final

extension SectionReorderPlannerTests {

    // MARK: - Subtree path (7, including the must-fix-2 out-of-document-order case and the
    // must-fix-3 mid-array relocation case)

    @Test("Subtree move: parent + children move together, preserving relative order, with a zero level delta")
    func subtreeBasicMove() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 2, title: "P")
        let child1 = makeSection(level: 3, title: "C1", parentId: parent.id)
        let child2 = makeSection(level: 3, title: "C2", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, parent, child1, child2]
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id, child2.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(titles(result) == ["Target", "P", "C1", "C2"])
        #expect(levels(result) == [1, 2, 3, 3])
    }

    @Test("Subtree move: negative level delta (promotion) shifts every moved section's level down by the same amount")
    func subtreePromotionDelta() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 3, title: "P")
        let child1 = makeSection(level: 4, title: "C1", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, parent, child1]
        // oldLevel = 3, newLevel = 1 -> delta = -2
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(levels(result) == [1, 1, 2])
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })
        #expect(movedParent.markdownContent == syncService.updateHeaderLevel(in: parent.markdownContent, to: 1))
        #expect(movedChild.markdownContent == syncService.updateHeaderLevel(in: child1.markdownContent, to: 2))
    }

    @Test("Subtree move: positive level delta (demotion) shifts every moved section's level up by the same amount")
    func subtreeDemotionDelta() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "P")
        let child1 = makeSection(level: 2, title: "C1", parentId: parent.id)
        let target = makeSection(level: 2, title: "Target")
        let sections = [target, parent, child1]
        // oldLevel = 1, newLevel = 3 -> delta = +2
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 3, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(levels(result) == [2, 3, 4])
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })
        #expect(movedParent.markdownContent == syncService.updateHeaderLevel(in: parent.markdownContent, to: 3))
        #expect(movedChild.markdownContent == syncService.updateHeaderLevel(in: child1.markdownContent, to: 4))
    }

    @Test("Subtree move: mid-array relocation with content on both sides exercises the removal/reinsertion index math (must-fix 3)")
    func subtreeMidArrayRelocationWithContentOnBothSides() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 2, title: "P")
        let child1 = makeSection(level: 3, title: "C1", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let tail = makeSection(level: 1, title: "Tail")
        // The moved subtree (P, C1) originates BEFORE the target, and other content (Tail)
        // exists after the target -- unlike the other subtree tests, where the target is
        // either the very last element or the moved block is already adjacent to it.
        let sections = [parent, child1, target, tail]
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(titles(result) == ["Target", "P", "C1", "Tail"])
    }

    @Test("Subtree move: a childId not present in sections is tolerated and silently skipped")
    func subtreeMissingChildIdTolerated() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "P")
        let child1 = makeSection(level: 2, title: "C1", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [target, parent, child1]
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id, "does-not-exist"]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(titles(result) == ["Target", "P", "C1"])
    }

    @Test(
        """
        Subtree move: newParentId is applied only to the moved parent section, not to its children \
        (children's parentId is recalculated elsewhere)
        """
    )
    func subtreeOnlyParentGetsNewParentId() throws {
        let syncService = SectionSyncService()
        let oldParent = makeSection(level: 1, title: "OldParent")
        let parent = makeSection(level: 2, title: "P", parentId: oldParent.id)
        let child1 = makeSection(level: 3, title: "C1", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        let sections = [oldParent, parent, child1, target]
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 2, newParentId: target.id,
            isSubtreeDrag: true, childIds: [child1.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))
        let movedParent = try #require(result.first { $0.title == "P" })
        let movedChild = try #require(result.first { $0.title == "C1" })

        #expect(movedParent.parentId == target.id)
        #expect(
            movedChild.parentId == parent.id,
            "children keep their existing parentId here -- recalculation happens outside this function"
        )
        #expect(titles(result) == ["OldParent", "Target", "P", "C1"])
    }

    @Test(
        """
        Subtree move: childIds arriving out of document order are reinserted in REQUEST order, not original \
        document order (must-fix 2 -- locks current behavior, does not change it)
        """
    )
    func subtreeChildIdsOutOfDocumentOrderFollowRequestOrder() throws {
        let syncService = SectionSyncService()
        let parent = makeSection(level: 1, title: "P")
        let a = makeSection(level: 2, title: "A", parentId: parent.id)
        let b = makeSection(level: 2, title: "B", parentId: parent.id)
        let target = makeSection(level: 1, title: "Target")
        // Document order is P, A, B, Target -- A precedes B in the document.
        let sections = [parent, a, b, target]
        // childIds lists B before A: the REVERSE of document order.
        let request = SectionReorderRequest(
            sectionId: parent.id, targetSectionId: target.id, newLevel: 1, newParentId: target.id,
            isSubtreeDrag: true, childIds: [b.id, a.id]
        )

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

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

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))
        let movedChild = try #require(result.first { $0.title == "Child" })

        #expect(movedChild.headerLevel == 1, "empty childIds must route through the single-section path, which promotes orphaned children")
    }

    // MARK: - Cross-check tying a no-op drop to dispatchSectionReorder's existing short-circuit

    @Test(
        """
        Cross-check: a no-op drop's planned order is recognized as unchanged by ContentView.sectionOrderUnchanged, \
        the same check dispatchSectionReorder uses to skip dispatch entirely
        """
    )
    func noOpPlanIsRecognizedByDispatchsExistingShortCircuit() throws {
        let syncService = SectionSyncService()
        let a = makeSection(level: 1, title: "A")
        let b = makeSection(level: 1, title: "B")
        let sections = [a, b]
        // B already directly follows A -- dropping B "after A" again is a structural no-op.
        let request = SectionReorderRequest(sectionId: b.id, targetSectionId: a.id, newLevel: 1, newParentId: nil)

        let result = try #require(planned(SectionReorderPlanner.plan(request: request, in: sections, syncService: syncService)))

        #expect(ContentView.sectionOrderUnchanged(result, from: sections))
    }
}
