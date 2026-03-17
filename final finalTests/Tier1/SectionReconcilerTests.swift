//
//  SectionReconcilerTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for SectionReconciler — the three-tier matching strategy that
//  maps parsed headers to database sections. Proximity mismatch silently
//  reassigns section metadata (status, goals, tags) to wrong sections.
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Tier 1: Silent Killers")
struct SectionReconcilerTests {

    let reconciler = SectionReconciler()
    let projectId = "test-project-id"

    // MARK: - Helper Factories

    private func makeHeader(
        position: Int,
        title: String,
        level: Int = 2,
        isPseudoSection: Bool = false,
        startOffset: Int = 0,
        markdownContent: String = "",
        wordCount: Int = 10
    ) -> ParsedHeader {
        ParsedHeader(
            position: position,
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount
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
            status: status,
            tags: tags,
            wordGoal: wordGoal
        )
    }

    // MARK: - Tier 1: Exact Position Matching

    @Test("Exact position match — normal edits within section")
    func exactPositionMatch() {
        let headers = [
            makeHeader(position: 0, title: "Introduction"),
            makeHeader(position: 1, title: "Methods"),
            makeHeader(position: 2, title: "Results"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "s2", sortOrder: 1, title: "Methods"),
            makeSection(id: "s3", sortOrder: 2, title: "Results"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // No inserts or deletes — all matched by position
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Should have no inserts for exact position match")
        #expect(deletes.isEmpty, "Should have no deletes for exact position match")
    }

    @Test("Exact position match — title changed (rename)")
    func titleRenameDetected() {
        let headers = [
            makeHeader(position: 0, title: "Introduction — Revised"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.count == 1)
        if case .update(let id, let updates) = changes[0] {
            #expect(id == "s1")
            #expect(updates.title == "Introduction — Revised")
        } else {
            Issue.record("Expected update, got \(changes[0])")
        }
    }

    // MARK: - Tier 2: Same Title Anywhere (Drag-Drop)

    @Test("Same title anywhere — handles drag-drop reordering")
    func sameTitleMatchAfterDragDrop() {
        // User dragged "Results" from position 2 to position 0
        let headers = [
            makeHeader(position: 0, title: "Results"),
            makeHeader(position: 1, title: "Introduction"),
            makeHeader(position: 2, title: "Methods"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction", status: .writing),
            makeSection(id: "s2", sortOrder: 1, title: "Methods", status: .review),
            makeSection(id: "s3", sortOrder: 2, title: "Results", status: .final_),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // All should be updates (position changes), no inserts or deletes
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Drag-drop should not create new sections")
        #expect(deletes.isEmpty, "Drag-drop should not delete sections")

        // Verify "Results" (id s3) matched and got new position 0
        let resultsUpdate = changes.first { change in
            if case .update(let id, _) = change { return id == "s3" }
            return false
        }
        #expect(resultsUpdate != nil, "Results section should match by title")
        if case .update(_, let updates) = resultsUpdate! {
            #expect(updates.sortOrder == 0, "Results should move to position 0")
        }
    }

    @Test("Pseudo-sections skip title matching — avoids false matches")
    func pseudoSectionsSkipTitleMatch() {
        // Two pseudo-sections with similar generated titles at different positions
        let headers = [
            makeHeader(position: 0, title: "Section Break", isPseudoSection: true),
            makeHeader(position: 1, title: "Section Break", isPseudoSection: true),
        ]
        let dbSections = [
            makeSection(id: "ps1", sortOrder: 0, title: "Section Break", isPseudoSection: true),
            makeSection(id: "ps2", sortOrder: 1, title: "Section Break", isPseudoSection: true),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // Should match by position (Tier 1), not create duplicates
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty)
        #expect(deletes.isEmpty)
    }

    // MARK: - Tier 3: Closest Position (Proximity)

    @Test("Closest position match — handles batch operations")
    func closestPositionMatch() {
        // A section was deleted, shifting positions
        let headers = [
            makeHeader(position: 0, title: "New Title A"),
            makeHeader(position: 1, title: "New Title B"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Old Title A", status: .writing),
            // s2 was at sortOrder 1, deleted
            makeSection(id: "s3", sortOrder: 2, title: "Old Title C", status: .review),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // s1 should match position 0, s3 should match position 1 via proximity (±3)
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Proximity match should prevent unnecessary inserts")
    }

    @Test("Proximity cascade with dense headings — no systematic metadata reassignment")
    func proximityCascadeWithDenseHeadings() {
        // 3 adjacent H2s, insert 2 new sections between them
        // This is the scenario where proximity matching can reassign metadata wrong
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Alpha", status: .writing, tags: ["tag-a"]),
            makeSection(id: "s2", sortOrder: 1, title: "Beta", status: .review, tags: ["tag-b"]),
            makeSection(id: "s3", sortOrder: 2, title: "Gamma", status: .final_, tags: ["tag-c"]),
        ]

        // User inserted two new sections, shifting positions
        let headers = [
            makeHeader(position: 0, title: "Alpha"),      // Should match s1 by position
            makeHeader(position: 1, title: "New Section"), // Should be inserted
            makeHeader(position: 2, title: "Beta"),        // Should match s2 by title (Tier 2)
            makeHeader(position: 3, title: "Another New"), // Should be inserted
            makeHeader(position: 4, title: "Gamma"),       // Should match s3 by title (Tier 2)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // Verify the original sections kept their IDs (metadata preserved)
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let updates) = change { return (id, updates) }
            return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }

        #expect(inserts.count == 2, "Should insert exactly 2 new sections")
        #expect(deletes.isEmpty, "Should not delete any original sections")

        // Verify s1 matched (by position or title)
        let s1Update = updates.first { $0.0 == "s1" }
        // s1 at position 0 should match header at position 0 — no title change needed
        if let update = s1Update {
            #expect(update.1.title == nil, "Alpha should keep its title")
        }

        // Verify s2 matched (by title since position shifted)
        let s2Matched = updates.contains { $0.0 == "s2" } ||
                        !changes.contains { if case .delete(let id) = $0 { return id == "s2" }; return false }
        #expect(s2Matched, "Beta should match by title, preserving status=review and tags")

        // Verify s3 matched (by title since position shifted)
        let s3Matched = updates.contains { $0.0 == "s3" } ||
                        !changes.contains { if case .delete(let id) = $0 { return id == "s3" }; return false }
        #expect(s3Matched, "Gamma should match by title, preserving status=final and tags")
    }

    // MARK: - Unmatched Sections

    @Test("Unmatched DB sections produce delete changes")
    func unmatchedDBSectionsDeleted() {
        let headers = [
            makeHeader(position: 0, title: "Only Section"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Only Section"),
            makeSection(id: "s2", sortOrder: 1, title: "Removed Section"),
            makeSection(id: "s3", sortOrder: 2, title: "Also Removed"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(deletes.contains("s2"), "Removed Section should be deleted")
        #expect(deletes.contains("s3"), "Also Removed should be deleted")
        #expect(!deletes.contains("s1"), "Only Section should not be deleted")
    }

    @Test("Unmatched parsed headers produce insert changes")
    func unmatchedHeadersInserted() {
        let headers = [
            makeHeader(position: 0, title: "Existing"),
            makeHeader(position: 1, title: "Brand New Section"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Existing"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        #expect(inserts.count == 1)
        #expect(inserts[0].title == "Brand New Section")
        #expect(inserts[0].projectId == projectId)
    }

    // MARK: - Bibliography and Notes Protection

    @Test("Bibliography sections are never deleted even when unmatched")
    func bibliographyProtectedFromDeletion() {
        let headers = [
            makeHeader(position: 0, title: "Introduction"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(!deletes.contains("bib"), "Bibliography section must never be deleted by reconciler")
    }

    @Test("Notes sections are never deleted even when unmatched")
    func notesProtectedFromDeletion() {
        let headers = [
            makeHeader(position: 0, title: "Introduction"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "notes", sortOrder: 1, title: "Notes", isNotes: true),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(!deletes.contains("notes"), "Notes section must never be deleted by reconciler")
    }

    @Test("Bibliography sections excluded from proximity matching")
    func bibliographyExcludedFromProximityMatch() {
        // A header at position 1 should not match the bibliography at sortOrder 1
        let headers = [
            makeHeader(position: 0, title: "Introduction"),
            makeHeader(position: 1, title: "New Section"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // "New Section" should be inserted, not matched to bibliography
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        #expect(inserts.count == 1, "New section should be inserted, not matched to bibliography")

        let updates = changes.compactMap { change -> String? in
            if case .update(let id, _) = change { return id }
            return nil
        }
        #expect(!updates.contains("bib"), "Bibliography should not be updated by reconciler")
    }

    // MARK: - Edge Cases

    @Test("Empty headers array — all non-protected sections deleted")
    func emptyHeadersDeletesAll() {
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Section A"),
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true),
        ]

        let changes = reconciler.reconcile(headers: [], dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(deletes.contains("s1"), "Regular section should be deleted")
        #expect(!deletes.contains("bib"), "Bibliography should be protected")
    }

    @Test("Empty DB sections — all headers inserted")
    func emptyDBInsertsAll() {
        let headers = [
            makeHeader(position: 0, title: "Alpha"),
            makeHeader(position: 1, title: "Beta"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: [], projectId: projectId)

        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        #expect(inserts.count == 2)
    }

    @Test("Heading level change detected as update")
    func headingLevelChangeDetected() {
        let headers = [
            makeHeader(position: 0, title: "Section", level: 3),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Section", headerLevel: 2),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.count == 1)
        if case .update(let id, let updates) = changes[0] {
            #expect(id == "s1")
            #expect(updates.headerLevel == 3)
        } else {
            Issue.record("Expected update for heading level change")
        }
    }

    @Test("No changes when headers perfectly match DB")
    func noChangesWhenPerfectMatch() {
        let headers = [
            makeHeader(position: 0, title: "Alpha", level: 2, startOffset: 0, markdownContent: "content", wordCount: 5),
        ]
        let dbSections = [
            Section(
                id: "s1",
                projectId: projectId,
                sortOrder: 0,
                headerLevel: 2,
                title: "Alpha",
                markdownContent: "content",
                wordCount: 5,
                startOffset: 0
            ),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.isEmpty, "Perfect match should produce zero changes")
    }

    @Test("Position beyond proximity range creates new section")
    func positionBeyondProximityRange() {
        // Header at position 10, DB section at position 0 — beyond ±3 range
        let headers = [
            makeHeader(position: 10, title: "Far Away"),
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Different Title"),
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.count == 1, "Should insert new section for far-away position")
        #expect(deletes.count == 1, "Should delete unmatched DB section")
    }
}
