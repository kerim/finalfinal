//
//  SectionSyncServiceZoomInsertionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Direct pin tests for `SectionSyncService.zoomedInsertionChanges` — the
//  trailing-section sortOrder-shift arithmetic extracted from
//  `syncZoomedSections` during the sectionsyncservice-lint cleanup. It is a
//  pure `nonisolated static` function, so these tests call it directly with
//  constructed inputs and assert on its exact outputs — no database fixture,
//  no debounce, no async machinery needed. Before this file, the function
//  was only exercised indirectly through higher-level tests, none of which
//  pinned its exact sortOrder arithmetic.
//

import Testing
import Foundation
@testable import final_final

@Suite("SectionSyncService.zoomedInsertionChanges — Tier 1: Silent Killers")
struct SectionSyncServiceZoomInsertionTests {

    let projectId = "test-project-id"

    // MARK: - Helper Factories

    private func makeHeader(
        title: String,
        level: Int = 2,
        isPseudoSection: Bool = false,
        startOffset: Int = 0,
        markdownContent: String = "",
        wordCount: Int = 10
    ) -> ParsedHeader {
        ParsedHeader(
            position: 0, // unused by zoomedInsertionChanges
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount
        )
    }

    private func makeSection(
        id: String,
        sortOrder: Int,
        title: String,
        headerLevel: Int = 2
    ) -> Section {
        Section(
            id: id,
            projectId: projectId,
            sortOrder: sortOrder,
            headerLevel: headerLevel,
            title: title
        )
    }

    // MARK: - No Insertion Needed

    @Test("headers.count == zoomedExisting.count — no insertion, no shift")
    func noInsertionWhenCountsAreEqual() {
        let zoomed = [makeSection(id: "z1", sortOrder: 5, title: "Zoomed")]
        let headers = [makeHeader(title: "Zoomed")]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: headers,
            zoomedExisting: zoomed,
            allSorted: zoomed,
            zoomedIds: ["z1"],
            pid: projectId
        )

        #expect(result.changes.isEmpty, "Equal counts should produce no changes")
        #expect(result.insertedIds.isEmpty, "Equal counts should insert nothing")
    }

    @Test("headers.count < zoomedExisting.count — no insertion (deletion is handled elsewhere)")
    func noInsertionWhenFewerHeadersThanZoomed() {
        let zoomed = [
            makeSection(id: "z1", sortOrder: 5, title: "Zoomed A"),
            makeSection(id: "z2", sortOrder: 6, title: "Zoomed B")
        ]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: [],
            zoomedExisting: zoomed,
            allSorted: zoomed,
            zoomedIds: ["z1", "z2"],
            pid: projectId
        )

        #expect(result.changes.isEmpty, "Fewer headers than zoomed sections should not trigger insertion logic")
        #expect(result.insertedIds.isEmpty)
    }

    // MARK: - Simple Single Insertion

    @Test("Single new header, no trailing sections — one insert, no shift")
    func simpleSingleInsertionWithNoTrailingSections() {
        let zoomed = [makeSection(id: "z1", sortOrder: 5, title: "Zoomed")]
        // Only the zoomed section exists document-wide — nothing after it to shift.
        let allSorted = zoomed
        let headers = [
            makeHeader(title: "Zoomed"),
            makeHeader(
                title: "New Section", level: 3, isPseudoSection: false,
                startOffset: 42, markdownContent: "## New Section\nBody.", wordCount: 2
            )
        ]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: headers,
            zoomedExisting: zoomed,
            allSorted: allSorted,
            zoomedIds: ["z1"],
            pid: projectId
        )

        #expect(result.changes.count == 1, "Should be exactly one insert change, no shift updates")

        guard case .insert(let newSection) = result.changes[0] else {
            Issue.record("Expected an insert change, got \(result.changes[0])")
            return
        }
        #expect(newSection.projectId == projectId)
        #expect(newSection.sortOrder == 6, "New section should land right after the zoomed section's sortOrder (5 + 1)")
        #expect(newSection.headerLevel == 3)
        #expect(newSection.isPseudoSection == false)
        #expect(newSection.title == "New Section")
        #expect(newSection.markdownContent == "## New Section\nBody.")
        #expect(newSection.wordCount == 2)
        #expect(newSection.startOffset == 42)

        #expect(result.insertedIds == [newSection.id], "insertedIds should contain exactly the new section's id")
    }

    // MARK: - Trailing-Section Shift Arithmetic (the risky part)

    @Test("Multiple new headers with trailing sections — shifts trailing sortOrders then inserts into freed slots")
    func trailingSectionsShiftToMakeRoomForMultipleInsertions() {
        let zoomed = [makeSection(id: "z1", sortOrder: 2, title: "Zoomed")]
        let trailingA = makeSection(id: "t1", sortOrder: 3, title: "Trailing A")
        let trailingB = makeSection(id: "t2", sortOrder: 4, title: "Trailing B")
        let allSorted = zoomed + [trailingA, trailingB]

        // 3 headers total: header[0] matches the existing zoomed section,
        // header[1] and header[2] are new (2 new headers -> newCount == 2).
        let headers = [
            makeHeader(title: "Zoomed"),
            makeHeader(title: "Inserted 1", startOffset: 10, markdownContent: "## Inserted 1", wordCount: 3),
            makeHeader(title: "Inserted 2", startOffset: 20, markdownContent: "## Inserted 2", wordCount: 4)
        ]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: headers,
            zoomedExisting: zoomed,
            allSorted: allSorted,
            zoomedIds: ["z1"],
            pid: projectId
        )

        #expect(result.changes.count == 4, "Expect 2 trailing-shift updates followed by 2 inserts")

        // First two changes: trailing sections shifted by newCount (2), in allSorted order.
        guard case .update(let firstShiftedId, let firstShiftedUpdates) = result.changes[0] else {
            Issue.record("Expected update at index 0, got \(result.changes[0])")
            return
        }
        #expect(firstShiftedId == "t1")
        #expect(firstShiftedUpdates.sortOrder == 5, "Trailing section at sortOrder 3 should shift to 3 + newCount(2) = 5")

        guard case .update(let secondShiftedId, let secondShiftedUpdates) = result.changes[1] else {
            Issue.record("Expected update at index 1, got \(result.changes[1])")
            return
        }
        #expect(secondShiftedId == "t2")
        #expect(secondShiftedUpdates.sortOrder == 6, "Trailing section at sortOrder 4 should shift to 4 + newCount(2) = 6")

        // Last two changes: inserts filling the freed sortOrder slots (3 and 4).
        guard case .insert(let firstInserted) = result.changes[2] else {
            Issue.record("Expected insert at index 2, got \(result.changes[2])")
            return
        }
        #expect(firstInserted.title == "Inserted 1")
        #expect(firstInserted.sortOrder == 3, "First new header fills the freed slot right after the zoomed section (2 + 1)")
        #expect(firstInserted.markdownContent == "## Inserted 1")
        #expect(firstInserted.wordCount == 3)
        #expect(firstInserted.startOffset == 10)

        guard case .insert(let secondInserted) = result.changes[3] else {
            Issue.record("Expected insert at index 3, got \(result.changes[3])")
            return
        }
        #expect(secondInserted.title == "Inserted 2")
        #expect(secondInserted.sortOrder == 4, "Second new header fills the next freed slot (2 + 2)")
        #expect(secondInserted.markdownContent == "## Inserted 2")
        #expect(secondInserted.wordCount == 4)
        #expect(secondInserted.startOffset == 20)

        #expect(
            result.insertedIds == [firstInserted.id, secondInserted.id],
            "insertedIds should contain exactly the two newly inserted section ids"
        )
    }

    @Test(
        """
        Multiple zoomed sections — lastZoomedSortOrder must come from .last, and shift/insert \
        math must use zoomedExisting.count, not a single-element coincidence
        """
    )
    func trailingSectionsShiftCorrectlyWithMultipleZoomedSections() {
        // Two zoomed sections with non-adjacent sortOrders (2 and 5) so that
        // `.last` vs `.first` and `(i - zoomedExisting.count)` vs bare `i` produce
        // different, distinguishable results instead of algebraically collapsing.
        let zoomedA = makeSection(id: "z1", sortOrder: 2, title: "Zoomed A")
        let zoomedB = makeSection(id: "z2", sortOrder: 5, title: "Zoomed B")
        let zoomed = [zoomedA, zoomedB]
        let trailingA = makeSection(id: "t1", sortOrder: 6, title: "Trailing A")
        let trailingB = makeSection(id: "t2", sortOrder: 7, title: "Trailing B")
        let allSorted = zoomed + [trailingA, trailingB]

        // 4 headers total: header[0]/[1] match the two existing zoomed sections,
        // header[2]/[3] are new (2 new headers -> newCount == 2).
        let headers = [
            makeHeader(title: "Zoomed A"),
            makeHeader(title: "Zoomed B"),
            makeHeader(title: "New Section 1", startOffset: 30, markdownContent: "## New Section 1", wordCount: 5),
            makeHeader(title: "New Section 2", startOffset: 40, markdownContent: "## New Section 2", wordCount: 6)
        ]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: headers,
            zoomedExisting: zoomed,
            allSorted: allSorted,
            zoomedIds: ["z1", "z2"],
            pid: projectId
        )

        // Hand trace against the real formulas:
        //   lastZoomedSortOrder = zoomedExisting.last?.sortOrder = 5  (z2, NOT z1's 2)
        //   newCount = headers.count(4) - zoomedExisting.count(2) = 2
        //   firstAfterZoomed = allSorted.first { sortOrder > 5 && not zoomed } = t1 (sortOrder 6)
        //   sectionsToShift = allSorted.filter { sortOrder >= 6 } = [t1, t2]
        //     t1: 6 + newCount(2) = 8
        //     t2: 7 + newCount(2) = 9
        //   inserts: for i in zoomedExisting.count(2)..<headers.count(4):
        //     i=2 (header[2] "New Section 1"): lastZoomedSortOrder(5) + (2 - 2) + 1 = 6
        //     i=3 (header[3] "New Section 2"): lastZoomedSortOrder(5) + (3 - 2) + 1 = 7
        //
        // If `.first` were swapped in for `.last`, lastZoomedSortOrder would be 2
        // (z1's sortOrder), giving insert sortOrders 3 and 4 instead of 6 and 7.
        // If the `(i - zoomedExisting.count)` term were dropped in favor of bare `i`,
        // insert sortOrders would be 7 and 8 instead of 6 and 7. Both mutations are
        // caught by this test's assertions below.

        #expect(result.changes.count == 4, "Expect 2 trailing-shift updates followed by 2 inserts")

        guard case .update(let firstShiftedId, let firstShiftedUpdates) = result.changes[0] else {
            Issue.record("Expected update at index 0, got \(result.changes[0])")
            return
        }
        #expect(firstShiftedId == "t1")
        #expect(firstShiftedUpdates.sortOrder == 8, "Trailing section at sortOrder 6 should shift to 6 + newCount(2) = 8")

        guard case .update(let secondShiftedId, let secondShiftedUpdates) = result.changes[1] else {
            Issue.record("Expected update at index 1, got \(result.changes[1])")
            return
        }
        #expect(secondShiftedId == "t2")
        #expect(secondShiftedUpdates.sortOrder == 9, "Trailing section at sortOrder 7 should shift to 7 + newCount(2) = 9")

        guard case .insert(let firstInserted) = result.changes[2] else {
            Issue.record("Expected insert at index 2, got \(result.changes[2])")
            return
        }
        #expect(firstInserted.title == "New Section 1")
        #expect(firstInserted.sortOrder == 6, "lastZoomedSortOrder(5, from .last) + (i=2 - zoomedExisting.count=2) + 1 = 6")
        #expect(firstInserted.markdownContent == "## New Section 1")
        #expect(firstInserted.wordCount == 5)
        #expect(firstInserted.startOffset == 30)

        guard case .insert(let secondInserted) = result.changes[3] else {
            Issue.record("Expected insert at index 3, got \(result.changes[3])")
            return
        }
        #expect(secondInserted.title == "New Section 2")
        #expect(secondInserted.sortOrder == 7, "lastZoomedSortOrder(5, from .last) + (i=3 - zoomedExisting.count=2) + 1 = 7")
        #expect(secondInserted.markdownContent == "## New Section 2")
        #expect(secondInserted.wordCount == 6)
        #expect(secondInserted.startOffset == 40)

        #expect(
            result.insertedIds == [firstInserted.id, secondInserted.id],
            "insertedIds should contain exactly the two newly inserted section ids"
        )
    }

    @Test("No trailing section exists after the zoomed section — no shift updates, only inserts")
    func noShiftWhenNothingFollowsZoomedSection() {
        // The zoomed section is last document-wide, so `allSorted.first { sortOrder > last }` finds nothing.
        let zoomed = [makeSection(id: "z1", sortOrder: 10, title: "Zoomed")]
        let allSorted = zoomed
        let headers = [
            makeHeader(title: "Zoomed"),
            makeHeader(title: "New A"),
            makeHeader(title: "New B")
        ]

        let result = SectionSyncService.zoomedInsertionChanges(
            headers: headers,
            zoomedExisting: zoomed,
            allSorted: allSorted,
            zoomedIds: ["z1"],
            pid: projectId
        )

        let updates = result.changes.filter { if case .update = $0 { return true }; return false }
        let inserts = result.changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        #expect(updates.isEmpty, "Nothing follows the zoomed section, so there should be no shift updates")
        #expect(inserts.count == 2)
        #expect(inserts[0].sortOrder == 11, "First new header: lastZoomedSortOrder(10) + (0) + 1")
        #expect(inserts[1].sortOrder == 12, "Second new header: lastZoomedSortOrder(10) + (1) + 1")
        #expect(result.insertedIds == Set(inserts.map(\.id)))
    }
}
