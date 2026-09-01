//
//  OutlineSidebarRenderKeyTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  bt t-ef411da3 (sidebar re-render investigation, round 3 -- the actual root-cause fix):
//  `ContentView` reconstructs `OutlineSidebar` fresh on every keystroke (it's a plain `View`
//  value, rebuilt every time `ContentView.body` runs). Rounds 1-2 fixed LEAF-level
//  over-invalidation (word-count extraction, `cardHeight`, tooltip extraction -- see
//  SidebarWordCountLeafTests.swift), but none of that could stop `OutlineSidebar.body` itself
//  from re-running on every single keystroke, because nothing told SwiftUI that a fresh
//  reconstruction with unchanged render-relevant content was the SAME value as before. This
//  round adds `OutlineSidebarRenderKey` and `OutlineSidebar: Equatable`
//  (OutlineSidebar+Models.swift) plus `.equatable()` at the `ContentView` call site, so SwiftUI
//  can finally skip `OutlineSidebar.body` entirely when nothing it renders actually changed.
//
//  What these tests DO cover: `OutlineSidebarRenderKey`'s own `==` (does it correctly compare
//  equal for a pure content edit and unequal for every render-relevant change?) and
//  `OutlineSidebar`'s own `==` operator built on top of it (does the operator correctly forward
//  to the key, and correctly compare the fields deliberately kept OUTSIDE the key --
//  `zoomedSectionIds`, `currentSectionId`, and closure-presence)?
//
//  What these tests do NOT and CANNOT cover (matching SidebarWordCountLeafTests.swift's own
//  documented limit): whether SwiftUI actually HONORS this `Equatable` conformance and skips
//  re-invoking `OutlineSidebar.body` at runtime. `Equatable` conformance plus `.equatable()` is
//  necessary but not sufficient -- a regression that removed `.equatable()` from the
//  `ContentView` call site (or built the `OutlineSidebar` value some other way that bypasses it)
//  would leave every test in this file green while `body` went right back to re-running on
//  every keystroke. That structural, live-app proof is `final finalUITests/
//  SidebarRerenderCountE2ETests.swift`'s keystroke-vs-body-invocation-count assertions instead --
//  these are unit tests of the comparison value/operator in isolation, not of SwiftUI's own
//  view-diffing behavior.
//

import Testing
import Foundation
import SwiftUI
@testable import final_final

@MainActor
@Suite("OutlineSidebar Render Key — Tier 1: Silent Killers")
struct OutlineSidebarRenderKeyTests {

    // MARK: - Helpers

    private func makeSection(
        title: String = "Untitled",
        wordCount: Int = 0,
        status: SectionStatus = .next,
        headerLevel: Int = 1,
        isBibliography: Bool = false,
        sortOrder: Int = 0
    ) -> SectionViewModel {
        SectionViewModel(from: Section(
            projectId: "test-project",
            sortOrder: sortOrder,
            headerLevel: headerLevel,
            isBibliography: isBibliography,
            title: title,
            status: status,
            wordCount: wordCount
        ))
    }

    private func makeKey(
        sections: [SectionViewModel],
        statusFilter: SectionStatus? = nil,
        headerLevelFilter: Int? = nil,
        zoomedSectionId: String? = nil,
        documentGoal: Int? = nil,
        documentGoalType: GoalType = .approx,
        excludeBibliography: Bool = false
    ) -> OutlineSidebarRenderKey {
        OutlineSidebarRenderKey(
            sections: sections,
            statusFilter: statusFilter,
            headerLevelFilter: headerLevelFilter,
            zoomedSectionId: zoomedSectionId,
            documentGoal: documentGoal,
            documentGoalType: documentGoalType,
            excludeBibliography: excludeBibliography
        )
    }

    /// Builds a real `OutlineSidebar` value for operator-level tests. Every callback that isn't
    /// under test is a harmless no-op/nil so each test can vary exactly one field and attribute
    /// any resulting inequality to that field alone.
    private func makeSidebar(
        sections: [SectionViewModel] = [],
        currentSectionId: String? = nil,
        zoomedSectionIds: Set<String>? = nil,
        onDeleteSection: ((String) -> Void)? = nil
    ) -> OutlineSidebar {
        OutlineSidebar(
            sections: .constant(sections),
            statusFilter: .constant(nil),
            headerLevelFilter: .constant(nil),
            zoomedSectionId: .constant(nil),
            zoomedSectionIds: zoomedSectionIds,
            renderKey: makeKey(sections: sections),
            documentGoal: .constant(nil),
            documentGoalType: .constant(.approx),
            excludeBibliography: .constant(false),
            onScrollToSection: { _ in },
            onSectionUpdated: { _ in },
            onSectionReorder: nil,
            currentSectionId: currentSectionId,
            onZoomToSection: nil,
            onZoomOut: nil,
            onDragStarted: nil,
            onDragEnded: nil,
            sectionDropInFlight: .constant(false),
            onDuplicateSection: nil,
            onDeleteSection: onDeleteSection
        )
    }

    // MARK: - Key-level: identity and content-edit stability

    @Test("identical sections and scalars produce an equal render key")
    func identicalInputsProduceEqualKeys() {
        let sections = [makeSection(title: "One", sortOrder: 0), makeSection(title: "Two", sortOrder: 1)]
        let a = makeKey(
            sections: sections, statusFilter: .writing, headerLevelFilter: 2, zoomedSectionId: "z",
            documentGoal: 500, documentGoalType: .min, excludeBibliography: true
        )
        let b = makeKey(
            sections: sections, statusFilter: .writing, headerLevelFilter: 2, zoomedSectionId: "z",
            documentGoal: 500, documentGoalType: .min, excludeBibliography: true
        )
        #expect(a == b)
    }

    // swiftlint:disable:next line_length
    @Test("LOAD-BEARING: editing a section's title and wordCount in place must not invalidate the render key -- a heading or body edit must not force the sidebar to re-render")
    func contentEditInPlaceDoesNotInvalidateKey() {
        let sections = [makeSection(title: "Original Title", wordCount: 10, sortOrder: 0)]
        let before = makeKey(sections: sections)

        // Mutated IN PLACE (same SectionViewModel reference, same ObjectIdentifier) -- exactly
        // how a live keystroke updates the sidebar's section list, per EditorViewState.mergeSections.
        sections[0].title = "Edited Title"
        sections[0].wordCount = 250

        let after = makeKey(sections: sections)
        #expect(after == before, "editing title/wordCount in place must not change the render key")
    }

    // MARK: - Key-level: per-section field changes each invalidate

    @Test("a status change invalidates the render key")
    func statusChangeInvalidatesKey() {
        let sections = [makeSection(status: .next, sortOrder: 0)]
        let before = makeKey(sections: sections)
        sections[0].status = .review
        #expect(makeKey(sections: sections) != before)
    }

    @Test("a sortOrder change invalidates the render key")
    func sortOrderChangeInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        let before = makeKey(sections: sections)
        sections[0].sortOrder = 5
        #expect(makeKey(sections: sections) != before)
    }

    @Test("an isBibliography flip invalidates the render key")
    func isBibliographyFlipInvalidatesKey() {
        let sections = [makeSection(isBibliography: false, sortOrder: 0)]
        let before = makeKey(sections: sections)
        sections[0].isBibliography = true
        #expect(makeKey(sections: sections) != before)
    }

    @Test("a headerLevel change invalidates the render key")
    func headerLevelChangeInvalidatesKey() {
        let sections = [makeSection(headerLevel: 1, sortOrder: 0)]
        let before = makeKey(sections: sections)
        sections[0].headerLevel = 2
        #expect(makeKey(sections: sections) != before)
    }

    @Test("adding a section invalidates the render key")
    func addingSectionInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        let before = makeKey(sections: sections)
        let withAdded = sections + [makeSection(title: "New", sortOrder: 1)]
        #expect(makeKey(sections: withAdded) != before)
    }

    @Test("removing a section invalidates the render key")
    func removingSectionInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0), makeSection(title: "Second", sortOrder: 1)]
        let before = makeKey(sections: sections)
        #expect(makeKey(sections: Array(sections.prefix(1))) != before)
    }

    // swiftlint:disable:next line_length
    @Test("swapping two sections' RAW-array position invalidates the render key -- deliberate over-invalidation (the safe direction), since renderSignature reads the unfiltered array")
    func rawArraySwapInvalidatesKey() {
        let sections = [makeSection(title: "First", sortOrder: 0), makeSection(title: "Second", sortOrder: 1)]
        let before = makeKey(sections: sections)
        let swapped = [sections[1], sections[0]]
        #expect(makeKey(sections: swapped) != before)
    }

    // MARK: - Key-level: each scalar independently invalidates

    @Test("statusFilter alone invalidates the render key")
    func statusFilterAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(makeKey(sections: sections, statusFilter: nil) != makeKey(sections: sections, statusFilter: .writing))
    }

    @Test("headerLevelFilter alone invalidates the render key")
    func headerLevelFilterAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeKey(sections: sections, headerLevelFilter: nil)
                != makeKey(sections: sections, headerLevelFilter: 2)
        )
    }

    @Test("zoomedSectionId alone invalidates the render key")
    func zoomedSectionIdAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeKey(sections: sections, zoomedSectionId: nil)
                != makeKey(sections: sections, zoomedSectionId: "section-1")
        )
    }

    @Test("documentGoal alone invalidates the render key")
    func documentGoalAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(makeKey(sections: sections, documentGoal: nil) != makeKey(sections: sections, documentGoal: 1000))
    }

    @Test("documentGoalType alone invalidates the render key")
    func documentGoalTypeAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeKey(sections: sections, documentGoalType: .approx)
                != makeKey(sections: sections, documentGoalType: .min)
        )
    }

    @Test("excludeBibliography alone invalidates the render key")
    func excludeBibliographyAloneInvalidatesKey() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeKey(sections: sections, excludeBibliography: false)
                != makeKey(sections: sections, excludeBibliography: true)
        )
    }

    // MARK: - Operator-level: OutlineSidebar's own Equatable

    @Test("identical OutlineSidebar values compare equal")
    func identicalSidebarsCompareEqual() {
        let sections = [makeSection(title: "One", sortOrder: 0)]
        #expect(makeSidebar(sections: sections) == makeSidebar(sections: sections))
    }

    @Test("differing currentSectionId makes OutlineSidebar values compare unequal")
    func differingCurrentSectionIdCompareUnequal() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeSidebar(sections: sections, currentSectionId: "a")
                != makeSidebar(sections: sections, currentSectionId: "b")
        )
    }

    @Test("differing zoomedSectionIds makes OutlineSidebar values compare unequal")
    func differingZoomedSectionIdsCompareUnequal() {
        let sections = [makeSection(sortOrder: 0)]
        #expect(
            makeSidebar(sections: sections, zoomedSectionIds: ["a"])
                != makeSidebar(sections: sections, zoomedSectionIds: ["b"])
        )
    }

    @Test("a nil vs non-nil onDeleteSection makes OutlineSidebar values compare unequal")
    func differingOnDeleteSectionPresenceCompareUnequal() {
        let sections = [makeSection(sortOrder: 0)]
        let withDelete = makeSidebar(sections: sections, onDeleteSection: { _ in })
        let withoutDelete = makeSidebar(sections: sections, onDeleteSection: nil)
        #expect(withDelete != withoutDelete)
    }

    // MARK: - Operator-level: `renderKey` is actually load-bearing in `==`
    //
    // Round-3 review finding: every operator-level test above holds `renderKey` CONSTANT across
    // both sides and only varies currentSectionId/zoomedSectionIds/onDeleteSection's nil-ness --
    // so deleting `lhs.renderKey == rhs.renderKey` from `OutlineSidebar.==` entirely would still
    // pass every one of them. That is exactly the failure mode this whole round exists to
    // prevent: an `==` that over-reports equality and silently freezes the sidebar against a
    // real section add/delete/reorder. These two tests vary `renderKey`'s own inputs (genuinely
    // different section content, and an in-place content-only edit) at the OPERATOR level, so a
    // regression that dropped the `renderKey` comparison term would fail
    // `genuinelyDifferentSectionsCompareUnequal` below.

    @Test("OutlineSidebar values built from genuinely different section content compare unequal")
    func genuinelyDifferentSectionsCompareUnequal() {
        let sectionsA = [makeSection(title: "One", status: .next, sortOrder: 0)]
        let sectionsB = [
            makeSection(title: "One", status: .next, sortOrder: 0),
            makeSection(title: "Two", status: .writing, sortOrder: 1)
        ]
        #expect(makeSidebar(sections: sectionsA) != makeSidebar(sections: sectionsB))
    }

    // swiftlint:disable:next line_length
    @Test("OutlineSidebar values built before and after an in-place title/wordCount-only edit still compare equal -- a heading or body edit must not invalidate the sidebar")
    func contentEditInPlaceKeepsSidebarsEqual() {
        let sections = [makeSection(title: "Original Title", wordCount: 10, sortOrder: 0)]
        let before = makeSidebar(sections: sections)

        // Mutated IN PLACE (same SectionViewModel references) between building the two
        // OutlineSidebar values -- exactly how a live keystroke updates the sidebar's section
        // list, per EditorViewState.mergeSections.
        sections[0].title = "Edited Title"
        sections[0].wordCount = 250

        let after = makeSidebar(sections: sections)
        #expect(after == before, "editing title/wordCount in place must not invalidate the sidebar")
    }
}
