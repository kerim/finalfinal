//
//  SectionReorderClampTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, plan U13 / B31): a section dropped below the LAST card of the Outline. `SectionReorderPlanner.plan` inserts a
//  dragged section AFTER the target, and the last cards of a book with footnotes (and a bibliography) are Notes and Bibliography, so the
//  planned order puts the section after them. The document never has that order and the editor refuses to carry it out (`managedMoved`);
//  `clampingManagedLeadersLast` puts every managed card last again (in their own order), leaving all the others where the plan put them,
//  so the drop lands just before Notes and stays an editor-first move.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("SectionReorderPlanner.clampingManagedLeadersLast — a drop below the last card lands before Notes (Tier 1)")
@MainActor
struct SectionReorderClampTests {

    private func card(_ id: String, notes: Bool = false, bibliography: Bool = false) -> SectionViewModel {
        SectionViewModel(from: Section(
            id: id, projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: bibliography, isNotes: notes,
            title: id, markdownContent: "# " + id))
    }

    /// The planner's own plan for dropping `moved` below the last card (`handleDropAtEnd`: the target is the last card's id).
    private func planned(moving moved: String, in sections: [SectionViewModel]) throws -> [SectionViewModel] {
        let request = SectionReorderRequest(sectionId: moved, targetSectionId: sections.last?.id, newLevel: 1, newParentId: nil)
        let result = SectionReorderPlanner.plan(request: request, in: sections, syncService: SectionSyncService())
        guard case .plan(let plan) = result else {
            Issue.record("the end drop of \(moved) produced no plan")
            return []
        }
        return plan
    }

    // U13: A dropped below the last card of a book that has Notes and a Bibliography. The planner puts it after them (the premise of
    // the fix); the clamp puts the managed cards last again, in their own order.
    @Test("dropBelowLastCardLandsBeforeNotes")
    func dropBelowLastCardLandsBeforeNotes() throws {
        let sections = [card("A"), card("B"), card("C"), card("Notes", notes: true), card("Bibliography", bibliography: true)]
        let plan = try planned(moving: "A", in: sections)
        #expect(
            plan.map(\.id) == ["B", "C", "Notes", "Bibliography", "A"],
            "premise: the planner drops A after the managed cards, got \(plan.map(\.id))")

        let clamped = SectionReorderPlanner.clampingManagedLeadersLast(plan)
        #expect(clamped.suffix(3).map(\.id) == ["A", "Notes", "Bibliography"], "the drop must land before Notes, got \(clamped.map(\.id))")
        #expect(clamped.map(\.id) == ["B", "C", "A", "Notes", "Bibliography"], "got \(clamped.map(\.id))")
    }

    // A book with footnotes but no bibliography: the last card is Notes itself (the end drop's target), and the section still lands
    // before it. The other cards keep the relative order the plan gave them.
    @Test("dropBelowNotesKeepsTheOtherCardsInPlannedOrder")
    func dropBelowNotesKeepsTheOtherCardsInPlannedOrder() throws {
        let sections = [card("A"), card("B"), card("C"), card("D"), card("Notes", notes: true)]
        let plan = try planned(moving: "B", in: sections)
        #expect(plan.map(\.id) == ["A", "C", "D", "Notes", "B"], "premise: the planner drops B after Notes, got \(plan.map(\.id))")

        let clamped = SectionReorderPlanner.clampingManagedLeadersLast(plan)
        #expect(clamped.map(\.id) == ["A", "C", "D", "B", "Notes"], "got \(clamped.map(\.id))")
    }

    // An article with no Notes and no Bibliography has nothing to clamp: the very same instances come back in the same order.
    @Test("noManagedCardsMeansNothingChanges")
    func noManagedCardsMeansNothingChanges() throws {
        let plan = [card("B"), card("C"), card("A")]
        let clamped = SectionReorderPlanner.clampingManagedLeadersLast(plan)
        #expect(clamped.map(\.id) == ["B", "C", "A"])
        #expect(zip(clamped, plan).allSatisfy { $0 === $1 }, "the clamp must return the same instances")
    }
}
