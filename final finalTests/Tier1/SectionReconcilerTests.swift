//
//  SectionReconcilerTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for SectionReconciler — the three-tier matching strategy that
//  maps parsed headers to database sections. Proximity mismatch silently
//  reassigns section metadata (status, goals, tags) to wrong sections.
//
//  Pseudo-section-specific matching tests live in
//  SectionReconcilerPseudoSectionTests.swift (split out to keep this file
//  under SwiftLint's file_length limit).
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Tier 1: Silent Killers")
// swiftlint:disable:next type_body_length
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

    // MARK: - Tier 1: Exact Position Matching

    @Test("Exact position match — normal edits within section")
    func exactPositionMatch() {
        let headers = [
            makeHeader(position: 0, title: "Introduction"),
            makeHeader(position: 1, title: "Methods"),
            makeHeader(position: 2, title: "Results")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "s2", sortOrder: 1, title: "Methods"),
            makeSection(id: "s3", sortOrder: 2, title: "Results")
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
            makeHeader(position: 0, title: "Introduction — Revised")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction")
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
        // After drag-drop, DB sortOrders are far from new header positions,
        // so Tier 1 (exact position match) and Tier 3 (±3 proximity) won't fire.
        // This forces Tier 2 (same title anywhere) to match by title.
        let headers = [
            makeHeader(position: 0, title: "Results"),       // was at sortOrder 20
            makeHeader(position: 1, title: "Introduction"),  // was at sortOrder 10
            makeHeader(position: 2, title: "Methods")       // was at sortOrder 15
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 10, title: "Introduction", status: .writing),
            makeSection(id: "s2", sortOrder: 15, title: "Methods", status: .review),
            makeSection(id: "s3", sortOrder: 20, title: "Results", status: .final_)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // All should be updates (position changes), no inserts or deletes
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Drag-drop should not create new sections")
        #expect(deletes.isEmpty, "Drag-drop should not delete sections")

        // Verify "Results" (id s3) matched by title and got new position 0
        let resultsUpdate = changes.first { change in
            if case .update(let id, _) = change { return id == "s3" }
            return false
        }
        #expect(resultsUpdate != nil, "Results section should match by title")
        if case .update(_, let updates) = resultsUpdate! {
            #expect(updates.sortOrder == 0, "Results should move to position 0")
        }
    }

    // MARK: - Tier 3: Closest Position (Proximity)

    @Test("Closest position match — handles batch operations")
    func closestPositionMatch() {
        // A section was deleted, shifting positions
        let headers = [
            makeHeader(position: 0, title: "New Title A"),
            makeHeader(position: 1, title: "New Title B")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Old Title A", status: .writing),
            // s2 was at sortOrder 1, deleted
            makeSection(id: "s3", sortOrder: 2, title: "Old Title C", status: .review)
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
            makeSection(id: "s3", sortOrder: 2, title: "Gamma", status: .final_, tags: ["tag-c"])
        ]

        // User inserted two new sections, shifting positions
        let headers = [
            makeHeader(position: 0, title: "Alpha"),      // Should match s1 by position
            makeHeader(position: 1, title: "New Section"), // Should be inserted
            makeHeader(position: 2, title: "Beta"),        // Should match s2 by title (Tier 2)
            makeHeader(position: 3, title: "Another New"), // Should be inserted
            makeHeader(position: 4, title: "Gamma")       // Should match s3 by title (Tier 2)
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

    // MARK: - Tier 1 Content-Relatedness Gate

    @Test("Delete-and-shift: later section must not steal the deleted section's slot")
    func deleteAndShiftDoesNotMisattributeIdentity() {
        // A(0), B(1), C(2) exist. User deletes B's header+body in one edit.
        // Reparsed headers become A(0), C(1) — C slides into B's old sortOrder slot.
        // Tier 1 must NOT claim B for C's header; Tier 2 (title match) must instead
        // correctly reattach "C" to DB row C, leaving B correctly unmatched/deleted.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body text discussing the setup."),
            makeHeader(position: 1, title: "C", markdownContent: "## C\nGamma body text discussing the results.")
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body text discussing the setup."),
            makeSection(id: "sB", sortOrder: 1, title: "B", markdownContent: "## B\nBeta body text, wholly unrelated."),
            makeSection(id: "sC", sortOrder: 2, title: "C", markdownContent: "## C\nGamma body text discussing the results.")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }

        #expect(deletes == ["sB"], "B (genuinely removed) should be deleted — not C")
        #expect(!updates.contains { $0.0 == "sB" }, "B's row must not be repurposed for C's content")

        let cUpdate = updates.first { $0.0 == "sC" }
        #expect(cUpdate != nil, "C should survive matched (via Tier 2 title match), keeping its own row")
        if let cUpdate {
            #expect(cUpdate.1.sortOrder == 1, "C should move to its new position 1")
            #expect(cUpdate.1.title == nil, "C's title is unchanged — no spurious title update")
        }
    }

    @Test("Delete-and-shift with empty bodies: two empty-content sections must not count as related")
    func deleteAndShiftDoesNotMisattributeIdentityWithEmptyBodies() {
        // Same A/B/C scenario as above, but all markdownContent is empty (a common
        // real state: skeleton/fresh headers). This specifically catches the ordering
        // bug the judge caught in contentRelated: if the `==` check runs before the
        // `isEmpty` guard, "" == "" short-circuits to true and Tier 1 wrongly claims
        // row B for header "C" purely because both have empty content. With the guard
        // ordered first, empty-vs-empty must return false, so Tier 1 refuses and Tier
        // 2's title match correctly rescues "C".
        let headers = [
            makeHeader(position: 0, title: "A"),
            makeHeader(position: 1, title: "C")
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A"),
            makeSection(id: "sB", sortOrder: 1, title: "B"),
            makeSection(id: "sC", sortOrder: 2, title: "C")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }

        #expect(deletes == ["sB"], "B (genuinely removed) should be deleted — not C — even with empty bodies")
        #expect(!updates.contains { $0.0 == "sB" }, "B's row must not be repurposed for C's identity")
        #expect(updates.contains { $0.0 == "sC" }, "C should survive matched via Tier 2 title match")
    }

    @Test("Tier 1 still claims: title-only rename with unchanged content")
    func tier1ClaimsTitleOnlyRename() {
        let headers = [
            makeHeader(position: 0, title: "Introduction, Revised", markdownContent: "## Introduction\nShared unchanged body.")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction", markdownContent: "## Introduction\nShared unchanged body.")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.count == 1, "Should be a single update, not an insert+delete")
        if case .update(let id, let updates) = changes.first {
            #expect(id == "s1")
            #expect(updates.title == "Introduction, Revised")
        } else {
            Issue.record("Expected a Tier 1 update, got \(changes)")
        }
    }

    @Test("Tier 1 still claims: content-only edit with unchanged title")
    func tier1ClaimsContentOnlyEdit() {
        let headers = [
            makeHeader(position: 0, title: "Methods", markdownContent: "## Methods\nRewritten body describing the revised procedure.")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Methods", markdownContent: "## Methods\nOriginal body describing the old procedure.")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.count == 1, "Should be a single update, not an insert+delete")
        if case .update(let id, let updates) = changes.first {
            #expect(id == "s1")
            #expect(updates.markdownContent == "## Methods\nRewritten body describing the revised procedure.")
            #expect(updates.title == nil, "Title unchanged — no spurious title update")
        } else {
            Issue.record("Expected a Tier 1 update, got \(changes)")
        }
    }

    @Test("Tier 1 still claims: combined title-rename + header-level change with unchanged body")
    func tier1ClaimsCombinedTitleAndLevelChange() {
        // Reasoned-through legitimate case: user promotes a subsection to a top-level
        // section (### -> ##) and renames it in the same edit, without touching the
        // body. Title alone differs from the DB row, so the gate must fall back to
        // content equality (unchanged body) rather than refusing the match — and
        // must NOT additionally require headerLevel equality (that would wrongly
        // block this exact legitimate case).
        let headers = [
            makeHeader(position: 0, title: "Background", level: 2, markdownContent: "### Prior Context\nUnchanged shared body text.")
        ]
        let dbSections = [
            makeSection(
                id: "s1", sortOrder: 0, title: "Prior Context", headerLevel: 3,
                markdownContent: "### Prior Context\nUnchanged shared body text."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.count == 1, "Should be a single update, not an insert+delete")
        if case .update(let id, let updates) = changes.first {
            #expect(id == "s1")
            #expect(updates.title == "Background")
            #expect(updates.headerLevel == 2)
        } else {
            Issue.record("Expected a Tier 1 update (matched via content equality), got \(changes)")
        }
    }

    // MARK: - Tier 3 Content-Relatedness Gate

    @Test("Tier 3 prefers related-but-farther candidate over closer-but-unrelated one")
    func tier3PrefersRelatedOverCloser() {
        // A(0) B(1) X(2) C(3) exist. User deletes B and X, and renames C -> D
        // in the same edit (body unchanged). Reparsed headers become A(0), D(1).
        // Tier 1 refuses (title/content both differ from B). Tier 2 fails (no DB
        // row titled "D" yet). Tier 3 must not grab B just because it's closest
        // (distance 0) -- it must prefer C (distance 2, but content-related) since
        // D's content is byte-identical to C's stored content.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "commonAlphaBody"),
            makeHeader(position: 1, title: "D", markdownContent: "commonDeltaBody")
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "commonAlphaBody"),
            makeSection(id: "sB", sortOrder: 1, title: "B", markdownContent: "commonBetaBody"),
            makeSection(id: "sX", sortOrder: 2, title: "X", markdownContent: "commonChiBody"),
            makeSection(id: "sC", sortOrder: 3, title: "C", markdownContent: "commonDeltaBody")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }

        #expect(deletes == ["sB", "sX"], "B and X (genuinely removed) should be deleted")
        let cUpdate = updates.first { $0.0 == "sC" }
        #expect(cUpdate != nil, "D should reattach to C's row (content-related), not B's (closer but unrelated)")
        if let cUpdate {
            #expect(cUpdate.1.sortOrder == 1, "C should move to its new position 1")
            #expect(cUpdate.1.title == "D", "C's title should update to D")
        }
    }

    // MARK: - Unmatched Sections

    @Test("Unmatched DB sections produce delete changes")
    func unmatchedDBSectionsDeleted() {
        let headers = [
            makeHeader(position: 0, title: "Only Section")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Only Section"),
            makeSection(id: "s2", sortOrder: 1, title: "Removed Section"),
            makeSection(id: "s3", sortOrder: 2, title: "Also Removed")
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
            makeHeader(position: 1, title: "Brand New Section")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Existing")
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
            makeHeader(position: 0, title: "Introduction")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true)
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
            makeHeader(position: 0, title: "Introduction")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "notes", sortOrder: 1, title: "Notes", isNotes: true)
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
            makeHeader(position: 1, title: "New Section")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true)
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
            makeSection(id: "bib", sortOrder: 1, title: "References", isBibliography: true)
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
            makeHeader(position: 1, title: "Beta")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: [], projectId: projectId)

        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        #expect(inserts.count == 2)
    }

    @Test("Heading level change detected as update")
    func headingLevelChangeDetected() {
        let headers = [
            makeHeader(position: 0, title: "Section", level: 3)
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Section", headerLevel: 2)
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
            makeHeader(position: 0, title: "Alpha", level: 2, startOffset: 0, markdownContent: "content", wordCount: 5)
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
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        #expect(changes.isEmpty, "Perfect match should produce zero changes")
    }

    @Test("Position beyond proximity range creates new section")
    func positionBeyondProximityRange() {
        // Header at position 10, DB section at position 0 — beyond ±3 range
        let headers = [
            makeHeader(position: 10, title: "Far Away")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Different Title")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.count == 1, "Should insert new section for far-away position")
        #expect(deletes.count == 1, "Should delete unmatched DB section")
    }
}
