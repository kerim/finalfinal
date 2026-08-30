//
//  SectionReconcilerSweepMigrationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Survivor-field-migration and bestFlaggedCandidate-tiebreak tests for SectionReconciler's
//  delete-sweep, split out of SectionReconcilerDeleteSweepTests.swift to keep that file
//  under SwiftLint's type_body_length limit (mirrors SectionReconcilerPseudoSectionTests.swift's
//  split from SectionReconcilerTests.swift).
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Delete-Sweep Migration & Tiebreak (Tier 1: Silent Killers)")
struct SectionReconcilerSweepMigrationTests {

    let reconciler = SectionReconciler()
    let projectId = "test-project-id"

    /// A `.deleteDuplicate` change's payload, named rather than an anonymous 3-member
    /// tuple (SwiftLint's large_tuple rule caps tuples at 2 members).
    private struct DeleteDuplicateChange {
        let loserId: String
        let survivorId: String
        let updates: SectionUpdates
    }

    // MARK: - Helper Factories

    private func makeHeader(
        position: Int,
        title: String,
        level: Int = 2,
        isPseudoSection: Bool = false,
        startOffset: Int = 0,
        markdownContent: String = "",
        wordCount: Int = 10,
        isBibliography: Bool = false,
        isNotes: Bool = false
    ) -> ParsedHeader {
        ParsedHeader(
            position: position,
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount,
            isBibliography: isBibliography,
            isNotes: isNotes
        )
    }

    private func makeSection(
        id: String = UUID().uuidString,
        sortOrder: Int,
        title: String,
        headerLevel: Int = 2,
        isPseudoSection: Bool = false,
        isBibliography: Bool = false,
        isNotes: Bool = false,
        markdownContent: String = "",
        status: SectionStatus = .writing,
        tags: [String] = ["important"],
        wordGoal: Int? = 500
    ) -> Section {
        Section(
            id: id,
            projectId: projectId,
            sortOrder: sortOrder,
            headerLevel: headerLevel,
            isPseudoSection: isPseudoSection,
            isBibliography: isBibliography,
            isNotes: isNotes,
            title: title,
            markdownContent: markdownContent,
            status: status,
            tags: tags,
            wordGoal: wordGoal
        )
    }

    @Test("Duplicate-sweep migration never clobbers a survivor's own real data")
    func duplicateSweepNeverClobbersSurvivorsRealData() {
        // Both rows carry real, DIFFERENT status/tags/wordGoal. mergeSurvivorUpdates
        // must leave the survivor's own values alone in every field -- there is no way
        // to know which side is "more real" from Section data alone, so ties go to
        // whichever row is already anchored to the live document.
        let headers = [
            makeHeader(position: 0, title: "Notes", isNotes: true)
        ]
        let dbSections = [
            makeSection(
                id: "notesSurvivor", sortOrder: 0, title: "Notes", isNotes: true,
                status: .review, tags: ["survivor-tag"], wordGoal: 200
            ),
            makeSection(
                id: "notesLoser", sortOrder: 1, title: "Notes", isNotes: true,
                status: .final_, tags: ["loser-tag"], wordGoal: 999
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deleteDuplicates = changes.compactMap { change -> DeleteDuplicateChange? in
            if case .deleteDuplicate(let loserId, let survivorId, let updates) = change {
                return DeleteDuplicateChange(loserId: loserId, survivorId: survivorId, updates: updates)
            }
            return nil
        }
        #expect(deleteDuplicates.count == 1)
        if let migration = deleteDuplicates.first {
            #expect(migration.loserId == "notesLoser")
            #expect(migration.survivorId == "notesSurvivor")
            #expect(migration.updates.status == nil, "Survivor already has a real status -- must not be clobbered")
            #expect(migration.updates.tags == nil, "Survivor already has real tags -- must not be clobbered")
            #expect(migration.updates.wordGoal == nil, "Survivor already has a real wordGoal -- must not be clobbered")
        }
    }

    @Test("Duplicate-sweep migration carries the loser's real data onto a still-default survivor")
    func duplicateSweepMigratesLosersDataOntoDefaultSurvivor() {
        // The survivor is left at Section's true defaults (.next status, empty tags, nil
        // wordGoal) -- there's nothing of its own to protect, so every one of the
        // loser's real values should migrate.
        let headers = [
            makeHeader(position: 0, title: "Notes", isNotes: true)
        ]
        let dbSections = [
            Section(
                id: "notesSurvivor", projectId: projectId, sortOrder: 0, headerLevel: 2,
                isNotes: true, title: "Notes"
            ),
            makeSection(
                id: "notesLoser", sortOrder: 1, title: "Notes", isNotes: true,
                status: .final_, tags: ["real-tag"], wordGoal: 750
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deleteDuplicates = changes.compactMap { change -> DeleteDuplicateChange? in
            if case .deleteDuplicate(let loserId, let survivorId, let updates) = change {
                return DeleteDuplicateChange(loserId: loserId, survivorId: survivorId, updates: updates)
            }
            return nil
        }
        #expect(deleteDuplicates.count == 1)
        if let migration = deleteDuplicates.first {
            #expect(migration.loserId == "notesLoser")
            #expect(migration.survivorId == "notesSurvivor")
            #expect(migration.updates.status == .final_, "Survivor was at the default -- the loser's real status must migrate")
            #expect(migration.updates.tags == ["real-tag"], "Survivor was at the default -- the loser's real tags must migrate")
            #expect(migration.updates.wordGoal == 750, "Survivor was at the default -- the loser's real wordGoal must migrate")
        }
    }

    @Test("bestFlaggedCandidate tiebreak is deterministic even when sortOrder also ties")
    func bestFlaggedCandidateTiebreakIsDeterministicOnSortOrderTie() {
        // Two flagged rows share the SAME sortOrder (not a unique key) and neither
        // clears passesMatchGate (titles differ from the header, no content overlap) --
        // every earlier tiebreak in bestFlaggedCandidate ties (evidence: neither: equal
        // distance-to-header.position: both 0). Without a final `id` fallback, `.min`
        // would return whichever row happened to come first in the incoming array --
        // non-deterministic across otherwise-identical calls, since neither
        // `dbSections`' caller-supplied order nor `sortedDB`'s sort of it is guaranteed
        // stable for equal sortOrders. With the `id` fallback, the lexicographically
        // smaller id always wins regardless of input order.
        let headers = [
            makeHeader(position: 3, title: "Notes", isNotes: true)
        ]
        let ascending = [
            makeSection(id: "aaa-notes", sortOrder: 3, title: "Unrelated Alpha", isNotes: true),
            makeSection(id: "zzz-notes", sortOrder: 3, title: "Unrelated Zulu", isNotes: true)
        ]
        let descending = Array(ascending.reversed())

        func survivorId(_ changes: [SectionChange]) -> String? {
            changes.compactMap { change -> String? in
                if case .update(let id, _) = change { return id }
                return nil
            }.first
        }

        let changesAscending = reconciler.reconcile(headers: headers, dbSections: ascending, projectId: projectId)
        let changesDescending = reconciler.reconcile(headers: headers, dbSections: descending, projectId: projectId)

        #expect(survivorId(changesAscending) == "aaa-notes", "Lexicographically smaller id should win the tie")
        #expect(survivorId(changesDescending) == "aaa-notes", "Result must not depend on dbSections' incoming order")
    }

    @Test("Nearest flagged Notes row wins on tie, not lowest sortOrder")
    func nearestFlaggedNotesRowWinsOnTie() {
        // Both rows clear passesMatchGate (same title as the header), so the tiebreak
        // must fall through to proximity — the nearer row to header.position wins, not
        // the row with the lowest sortOrder (the old, arbitrary selection rule).
        let headers = [
            makeHeader(position: 5, title: "Notes", isNotes: true)
        ]
        let dbSections = [
            makeSection(id: "notesFar", sortOrder: 0, title: "Notes", isNotes: true),
            makeSection(id: "notesNear", sortOrder: 6, title: "Notes", isNotes: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deleteDuplicates = changes.compactMap { change -> (loserId: String, survivorId: String)? in
            if case .deleteDuplicate(let loserId, let survivorId, _) = change { return (loserId, survivorId) }
            return nil
        }

        #expect(
            updates.contains { $0.0 == "notesNear" },
            "Nearer row (distance 1) should be matched, not the lowest-sortOrder one (distance 5)"
        )
        #expect(deleteDuplicates.count == 1)
        #expect(deleteDuplicates.first?.loserId == "notesFar", "Farther row must be swept as the loser")
        #expect(deleteDuplicates.first?.survivorId == "notesNear")
    }
}
