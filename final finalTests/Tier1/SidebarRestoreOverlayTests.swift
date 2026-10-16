//
//  SidebarRestoreOverlayTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2b; the first real-app runs, VM test testQuickUndoTiming_article): where a quick-undone section's
//  leaders go in the sidebar while the database does not hold their rows yet. The bug: the overlay placed them by their OLD sort orders
//  against the renumbered current ones, so the last body section's sub-heading landed after "# Notes" (level 1), hierarchy enforcement
//  patched its level in the database and wiped the redo stack. The rule now is the document anchor (`SidebarRestoreOverlay`), and
//  enforcement waits while a restore is pending.
//    - U-Q38  (sw64)  the pure overlay places the last body section by its anchor (`Block` and `SectionViewModel` lists); the anchor itself
//    - U-Q38b         the anchor for the document start, a paragraph before it, a section break, and unknown rows
//    - U-Q38c         the old sort-order rule where no usable anchor exists; no leader twice; restores anchored on an earlier restore
//    - U-Q39  (sw65)  `EditorViewState.mergingPendingRestores` (and `withoutPendingRemovals`) use the anchor the state recorded
//    - U-Q41  (sw67)  `ContentView.hierarchyEnforcementWaitsForQuickUndo`: true while an overlay entry or a pending reinsert exists
//
//  The sidebar's whole flow (U-Q40) and the default of the measurement seam (U-Q42) are in Tier2/QuickUndoSidebarRestoreTests.swift.
//

import Foundation
import Testing
@testable import final_final

@Suite("Quick undo: where a restored section goes in the sidebar (Tier 1)")
@MainActor
struct SidebarRestoreOverlayTests {

    // MARK: - The article's last body section, as the first VM runs met it

    private func heading(_ title: String, level: Int, order: Double, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: "id-" + title, projectId: "p", sortOrder: order, blockType: .heading, textContent: title,
            markdownFragment: String(repeating: "#", count: level) + " " + title, headingLevel: level,
            isBibliography: bibliography, isNotes: notes)
    }

    private func paragraph(_ text: String, order: Double) -> Block {
        Block(id: "id-" + text, projectId: "p", sortOrder: order, blockType: .paragraph, textContent: text, markdownFragment: text)
    }

    /// The outline after "1.5" was deleted (the rows that followed were renumbered to close the gap: Conclusion has the number 1.5 had,
    /// Notes is below the old number of 1.5.2), the leaders of the restore with their OLD numbers, and the document as it was before.
    private struct LastBodySection {
        let outline: [Block]
        let leaders: [Block]
        let preDeleteRows: [Block]
        let expectedIds: [String]
    }

    private func lastBodySection() -> LastBodySection {
        let outline = [
            heading("Title", level: 1, order: 1), heading("1.1", level: 2, order: 10), heading("1.4", level: 2, order: 60),
            heading("1.4.2", level: 3, order: 69), heading("Conclusion", level: 2, order: 74),
            heading("Notes", level: 1, order: 79, notes: true), heading("Bibliography", level: 1, order: 89, bibliography: true)
        ]
        let leaders = [heading("1.5", level: 2, order: 74), heading("1.5.1", level: 3, order: 78), heading("1.5.2", level: 3, order: 83)]
        let preDeleteRows = [
            heading("Title", level: 1, order: 1), paragraph("intro", order: 2), heading("1.1", level: 2, order: 10),
            paragraph("one", order: 11), heading("1.4", level: 2, order: 60), paragraph("four", order: 61),
            heading("1.4.2", level: 3, order: 69), paragraph("four-two", order: 70), leaders[0], paragraph("five", order: 75),
            leaders[1], paragraph("five-one", order: 79), leaders[2], paragraph("five-two", order: 84),
            heading("Conclusion", level: 2, order: 90), paragraph("end", order: 91), heading("Notes", level: 1, order: 95, notes: true),
            heading("Bibliography", level: 1, order: 99, bibliography: true)
        ]
        let titles = ["Title", "1.1", "1.4", "1.4.2", "1.5", "1.5.1", "1.5.2", "Conclusion", "Notes", "Bibliography"]
        return LastBodySection(outline: outline, leaders: leaders, preDeleteRows: preDeleteRows, expectedIds: titles.map { "id-" + $0 })
    }

    @Test("U-Q38 (VM bug): the last body section goes right after the heading that stood before it, not by its stale sort order")
    func testOverlayPlacesTheLastBodySectionByAnchorNotByStaleSortOrder() {
        let doc = lastBodySection()

        let anchor = SidebarRestoreOverlay.anchor(for: doc.leaders, inPreDeleteRows: doc.preDeleteRows)
        #expect(anchor == .after("id-1.4.2"), "the heading before the section in the pre-delete document: \(String(describing: anchor))")

        let merged = SidebarRestoreOverlay.merging([PendingRestore(leaders: doc.leaders, anchor: anchor)], into: doc.outline)
        #expect(merged.map(\.id) == doc.expectedIds, "expected ...1.4.2, 1.5, 1.5.1, 1.5.2, Conclusion, Notes, Bibliography")
        let violations = ContentView.hasHierarchyViolations(in: merged.map { SectionViewModel(from: $0) })
        #expect(!violations, "no heading may follow Notes at a level it cannot have")

        // The sidebar's own list is `SectionViewModel`s: the same rule, the same answer.
        let sidebar = PendingRestore(leaders: doc.leaders.map { SectionViewModel(from: $0) }, anchor: anchor)
        let sections = SidebarRestoreOverlay.merging([sidebar], into: doc.outline.map { SectionViewModel(from: $0) })
        #expect(sections.map(\.id) == doc.expectedIds, "the sidebar's own list takes the same rule")
        #expect(!ContentView.hasHierarchyViolations(in: sections), "the sidebar's list has no hierarchy violation")
    }

    // MARK: - The anchor itself

    @Test("U-Q38b: the anchor is the nearest earlier outline block that is not restored; the document start; nil when the rows are unknown")
    func testAnchorForLeaders() {
        let doc = lastBodySection()
        let firstSection = [doc.preDeleteRows[2]]   // "1.1": a heading that is not the first row
        #expect(SidebarRestoreOverlay.anchor(for: firstSection, inPreDeleteRows: doc.preDeleteRows) == .after("id-Title"))

        let atStart = [heading("Opening", level: 1, order: 1), paragraph("text", order: 2), heading("Next", level: 1, order: 3)]
        #expect(SidebarRestoreOverlay.anchor(for: [atStart[0]], inPreDeleteRows: atStart) == .documentStart, "nothing before the heading")

        let afterText = [paragraph("preface", order: 1)] + atStart
        #expect(
            SidebarRestoreOverlay.anchor(for: [afterText[1]], inPreDeleteRows: afterText) == .documentStart,
            "a paragraph is not an outline block: still the document start")

        let sectionBreak = Block(
            id: "id-break", projectId: "p", sortOrder: 2, blockType: .paragraph, textContent: "", markdownFragment: "", headingLevel: 1,
            isPseudoSection: true)
        let withBreak = [heading("Opening", level: 1, order: 1), sectionBreak, heading("Later", level: 2, order: 3)]
        #expect(SidebarRestoreOverlay.anchor(for: [withBreak[2]], inPreDeleteRows: withBreak) == .after("id-break"), "a section break anchors")

        #expect(SidebarRestoreOverlay.anchor(for: doc.leaders, inPreDeleteRows: []) == nil, "the pre-delete rows are not known")
        #expect(SidebarRestoreOverlay.anchor(for: [heading("Elsewhere", level: 2, order: 5)], inPreDeleteRows: atStart) == nil, "not in the rows")
        #expect(SidebarRestoreOverlay.anchor(for: [], inPreDeleteRows: atStart) == nil, "no leaders")
    }

    // MARK: - Where the anchor cannot be used

    @Test("U-Q38c: without a usable anchor the old sort-order rule applies; a leader the list has is not added twice; restores chain")
    func testFallbackAndChaining() {
        let outline = [
            heading("One", level: 1, order: 1), heading("Three", level: 1, order: 3), heading("Bib", level: 1, order: 9, bibliography: true)
        ]
        let two = heading("Two", level: 1, order: 2)
        let expected = ["id-One", "id-Two", "id-Three", "id-Bib"]
        func placed(_ anchor: RestoreAnchor?) -> [String] {
            SidebarRestoreOverlay.merging([PendingRestore(leaders: [two], anchor: anchor)], into: outline).map(\.id)
        }
        #expect(placed(nil) == expected, "no anchor recorded: by sort order")
        #expect(placed(.after("id-Gone")) == expected, "the anchor is not in the list: by sort order")
        #expect(placed(.after("id-Bib")) == expected, "the bibliography is never an anchor (it stays last): by sort order")
        #expect(placed(.documentStart) == ["id-Two", "id-One", "id-Three", "id-Bib"], "the document start is first")

        let twice = SidebarRestoreOverlay.merging([PendingRestore(leaders: [outline[1]], anchor: .after("id-One"))], into: outline)
        #expect(twice.map(\.id) == outline.map(\.id), "a leader the list already has is not added twice")

        // A later restore anchored on a leader an earlier one has just put in (its first leader's old number is larger).
        let four = heading("Four", level: 2, order: 4)
        let chained = SidebarRestoreOverlay.merging(
            [PendingRestore(leaders: [four], anchor: .after("id-Two")), PendingRestore(leaders: [two], anchor: .after("id-One"))],
            into: outline)
        #expect(chained.map(\.id) == ["id-One", "id-Two", "id-Four", "id-Three", "id-Bib"], "a later restore anchored on an earlier restore's leader")
    }

    // MARK: - The editor state's own merge (U-Q39)

    @Test("U-Q39 (VM bug): the editor state merges a pending restore by the anchor it recorded, and drops the anchor with the entry")
    func testMergingPendingRestoresUsesTheRecordedAnchor() {
        let doc = lastBodySection()
        let state = EditorViewState()
        let opId = UUID()
        state.pendingRestoreSections[opId] = doc.leaders
        state.pendingRestoreAnchors[opId] = SidebarRestoreOverlay.anchor(for: doc.leaders, inPreDeleteRows: doc.preDeleteRows)

        let merged = state.mergingPendingRestores(into: doc.outline).map(\.id)
        #expect(merged == doc.expectedIds, "expected the restored section right after its anchor")
        let outlineResult = state.withoutPendingRemovals(doc.outline).map(\.id)
        #expect(outlineResult == doc.expectedIds, "the outline results take the same route")

        state.pendingRestoreSections[opId] = nil   // the reinsert has put the rows back
        #expect(state.pendingRestoreAnchors.isEmpty, "the anchor goes with its overlay entry")
        #expect(state.mergingPendingRestores(into: doc.outline).map(\.id) == doc.outline.map(\.id), "nothing is merged any more")
    }

    // MARK: - Enforcement waits (U-Q41)

    @Test("U-Q41 (VM bug): hierarchy enforcement waits while a quick undo's restore is pending, and only then")
    func testHierarchyEnforcementWaitsWhileAQuickUndoRestoreIsPending() {
        let state = EditorViewState()
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "nothing pending: enforcement runs as before")

        state.pendingRestoreSections[UUID()] = [heading("1.5", level: 2, order: 74)]
        #expect(ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "expected the check to wait while an overlay entry exists, got false")
        state.pendingRestoreSections = [:]
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "the overlay is gone: enforcement may run")

        state.pendingReinsertCount = 1
        #expect(ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "expected the check to wait while a reinsert is pending, got false")
        state.pendingReinsertCount = 0
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "the reinsert has ended: enforcement may run")

        // The sidebar update waits for the editor's next frame: its window is pending work too, even when the reinsert has resolved.
        state.pendingSidebarRestoreCount = 1
        #expect(
            ContentView.hierarchyEnforcementWaitsForQuickUndo(state),
            "expected the check to wait while only the sidebar update is pending, got false")
        state.pendingSidebarRestoreCount = 0
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(state), "the update has run: enforcement may run")
    }
}
