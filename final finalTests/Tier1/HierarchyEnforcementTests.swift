//
//  HierarchyEnforcementTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for hierarchy enforcement delta propagation.
//  Verifies that sibling sections at the same level are normalized together,
//  not just the first child.
//

import Testing
import Foundation
@testable import final_final

@Suite("Hierarchy Enforcement — Tier 1: Silent Killers")
struct HierarchyEnforcementTests {

    // MARK: - Helpers

    /// Build a SectionViewModel with the given header level and markdown content.
    /// Title is extracted from the markdown header prefix.
    private func makeSection(
        id: String = UUID().uuidString,
        level: Int,
        title: String
    ) -> SectionViewModel {
        let markdown = String(repeating: "#", count: level) + " " + title
        return SectionViewModel(from: Section(
            id: id,
            projectId: "test",
            sortOrder: 0,
            headerLevel: level,
            title: title,
            markdownContent: markdown
        ))
    }

    /// Extract header levels from sections array for easy assertion.
    private func levels(_ sections: [SectionViewModel]) -> [Int] {
        sections.map(\.headerLevel)
    }

    // MARK: - Test Cases

    @Test("Sibling normalization — the original bug")
    @MainActor
    func siblingNormalization() {
        // # T, ## 1, #### 2, #### 3, #### 4 -> # T, ## 1, ### 2, ### 3, ### 4
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 2, title: "1"),
            makeSection(level: 4, title: "2"),
            makeSection(level: 4, title: "3"),
            makeSection(level: 4, title: "4")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 3, 3, 3])
    }

    @Test("Nested subtree normalization")
    @MainActor
    func nestedSubtree() {
        // # T, ## A, #### B, ##### C, #### D -> # T, ## A, ### B, #### C, ### D
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 2, title: "A"),
            makeSection(level: 4, title: "B"),
            makeSection(level: 5, title: "C"),
            makeSection(level: 4, title: "D")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 3, 4, 3])
    }

    @Test("Subtree exit — delta resets at lower level")
    @MainActor
    func subtreeExit() {
        // # T, ## A, #### B, #### C, ## D, #### E
        // -> # T, ## A, ### B, ### C, ## D, ### E
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 2, title: "A"),
            makeSection(level: 4, title: "B"),
            makeSection(level: 4, title: "C"),
            makeSection(level: 2, title: "D"),
            makeSection(level: 4, title: "E")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 3, 3, 2, 3])
    }

    @Test("H1 first rule + delta propagation")
    @MainActor
    func h1FirstRulePlusDelta() {
        // ### A, #### B, #### C -> # A, ## B, ## C
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 3, title: "A"),
            makeSection(level: 4, title: "B"),
            makeSection(level: 4, title: "C")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 2])
    }

    @Test("4-deep nesting chain — no double-clamping")
    @MainActor
    func fourDeepNestingChain() {
        // # T, ## A, ##### B, ###### C, ##### D
        // B: 5 -> 3, delta=-2, floor=5
        // C: 6 >= 5, level=6+(-2)=4, 4 <= 3+1=4 ✓
        // D: 5 >= 5, level=5+(-2)=3, 3 <= 4+1=5 ✓
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 2, title: "A"),
            makeSection(level: 5, title: "B"),
            makeSection(level: 6, title: "C"),
            makeSection(level: 5, title: "D")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 3, 4, 3])
    }

    @Test("Two independent subtrees corrected independently")
    @MainActor
    func twoIndependentSubtrees() {
        // # T, #### A, #### B, ### Sep, ##### C, ##### D
        // A: 4 -> 2 (max=1+1=2), delta=-2, floor=4
        // B: 4 >= 4, level=4+(-2)=2, 2 <= 2+1=3 ✓
        // Sep: 3 < 4, delta resets. 3 <= 2+1=3 ✓
        // C: 5 -> 4 (max=3+1=4), delta=-1, floor=5
        // D: 5 >= 5, level=5+(-1)=4, 4 <= 4+1=5 ✓
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 4, title: "A"),
            makeSection(level: 4, title: "B"),
            makeSection(level: 3, title: "Sep"),
            makeSection(level: 5, title: "C"),
            makeSection(level: 5, title: "D")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 2, 3, 4, 4])
    }

    @Test("No-op when hierarchy is already valid")
    @MainActor
    func noOpWhenValid() {
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "T"),
            makeSection(level: 2, title: "A"),
            makeSection(level: 3, title: "B"),
            makeSection(level: 2, title: "C")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2, 3, 2])
    }

    @Test("No regression — basic predecessor constraint")
    @MainActor
    func basicPredecessorConstraint() {
        // # A, ### B -> # A, ## B
        let syncService = SectionSyncService()
        var sections = [
            makeSection(level: 1, title: "A"),
            makeSection(level: 3, title: "B")
        ]

        ContentView.enforceHierarchyConstraintsStatic(sections: &sections, syncService: syncService)

        #expect(levels(sections) == [1, 2])
    }
}
