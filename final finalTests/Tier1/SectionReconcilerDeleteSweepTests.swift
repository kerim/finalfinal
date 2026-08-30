//
//  SectionReconcilerDeleteSweepTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Orphaned duplicate flagged-row delete-sweep tests for SectionReconciler,
//  split out of SectionReconcilerTests.swift to keep that file under
//  SwiftLint's file_length limit (mirrors SectionReconcilerPseudoSectionTests.swift).
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Orphaned Duplicate Delete-Sweep (Tier 1: Silent Killers)")
struct SectionReconcilerDeleteSweepTests {

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

    // MARK: - Orphaned Duplicate Flagged Row Delete-Sweep

    @Test("Orphaned duplicate Notes row is swept")
    func orphanedDuplicateNotesRowIsSwept() {
        // Two isNotes rows exist (a duplicate created by some other, out-of-scope bug).
        // The live row matches the parsed Notes header by title; the orphan, sitting
        // AFTER it, matches nothing. Before this fix, the delete-sweep's inline
        // `section.isNotes && !notesGone` check exempted EVERY unmatched isNotes row
        // whenever the flag survived anywhere in the document -- so the orphan would
        // never be swept. It must be swept now that the live row has genuinely claimed
        // the match -- via `.deleteDuplicate` (not a plain `.delete`), since a survivor
        // exists for the orphan's data to migrate onto before it's deleted.
        let headers = [
            makeHeader(position: 0, title: "Notes", isNotes: true)
        ]
        let dbSections = [
            makeSection(id: "notesLive", sortOrder: 0, title: "Notes", isNotes: true),
            makeSection(id: "notesOrphan", sortOrder: 1, title: "Notes", isNotes: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let plainDeletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        let deleteDuplicates = changes.compactMap { change -> (loserId: String, survivorId: String)? in
            if case .deleteDuplicate(let loserId, let survivorId, _) = change { return (loserId, survivorId) }
            return nil
        }
        #expect(plainDeletes.isEmpty, "A survivor exists this pass, so this must be .deleteDuplicate, not a plain .delete")
        #expect(deleteDuplicates.count == 1)
        #expect(deleteDuplicates.first?.loserId == "notesOrphan", "Orphan should be swept, not the live row")
        #expect(deleteDuplicates.first?.survivorId == "notesLive", "Data should migrate onto the live (matched) row")
    }

    @Test("Orphaned duplicate Bibliography row is swept")
    func orphanedDuplicateBibliographyRowIsSwept() {
        // Mirror of orphanedDuplicateNotesRowIsSwept for isBibliography.
        let headers = [
            makeHeader(position: 0, title: "References", isBibliography: true)
        ]
        let dbSections = [
            makeSection(id: "bibLive", sortOrder: 0, title: "References", isBibliography: true),
            makeSection(id: "bibOrphan", sortOrder: 1, title: "References", isBibliography: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let plainDeletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        let deleteDuplicates = changes.compactMap { change -> (loserId: String, survivorId: String)? in
            if case .deleteDuplicate(let loserId, let survivorId, _) = change { return (loserId, survivorId) }
            return nil
        }
        #expect(plainDeletes.isEmpty, "A survivor exists this pass, so this must be .deleteDuplicate, not a plain .delete")
        #expect(deleteDuplicates.count == 1)
        #expect(deleteDuplicates.first?.loserId == "bibOrphan", "Orphan should be swept, not the live row")
        #expect(deleteDuplicates.first?.survivorId == "bibLive", "Data should migrate onto the live (matched) row")
    }

    @Test("Duplicate Notes rows survive when no Notes header is parsed this pass")
    func duplicateNotesRowsSurviveWhenNoNotesHeaderParsed() {
        // Regression guard for part (b) of isExemptFromDeleteSweep's doc comment: when
        // NEITHER duplicate row matches anything this pass (the sync service hasn't run,
        // or the header just hasn't been parsed yet), both must stay exempt -- exactly
        // the pre-fix behavior. This fix only narrows the case where a DIFFERENT row of
        // the same flag already won the match; it must not start sweeping rows just
        // because there happen to be two of them.
        let headers = [
            makeHeader(position: 0, title: "Introduction")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "notesA", sortOrder: 1, title: "Notes", isNotes: true),
            makeSection(id: "notesB", sortOrder: 2, title: "Notes", isNotes: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(!deletes.contains("notesA"), "Neither duplicate should be swept with no Notes header parsed")
        #expect(!deletes.contains("notesB"), "Neither duplicate should be swept with no Notes header parsed")
    }

    @Test("Duplicate Notes rows are all swept when Notes is verifiably gone")
    func duplicateNotesRowsAllSweptWhenNotesGone() {
        // Regression guard: when Notes is verifiably gone via BOTH signals
        // (notesExistsInBlocks: false AND no parsed header is isNotes), every unmatched
        // Notes row -- duplicate or not -- must still be swept, exactly like the
        // single-row case this exemption already handled before this fix.
        let headers = [
            makeHeader(position: 0, title: "Introduction")
        ]
        let dbSections = [
            makeSection(id: "s1", sortOrder: 0, title: "Introduction"),
            makeSection(id: "notesA", sortOrder: 1, title: "Notes", isNotes: true),
            makeSection(id: "notesB", sortOrder: 2, title: "Notes", isNotes: true)
        ]

        let changes = reconciler.reconcile(
            headers: headers, dbSections: dbSections, projectId: projectId,
            notesExistsInBlocks: false
        )

        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        #expect(deletes.contains("notesA"), "Both duplicates should be swept once Notes is verifiably gone")
        #expect(deletes.contains("notesB"), "Both duplicates should be swept once Notes is verifiably gone")
    }

    @Test("Stale earlier Notes orphan loses to the evidence-bearing row, and its real data migrates")
    func staleEarlierNotesOrphanLosesToEvidenceBearingRow() {
        // Regression for the original selection bug: before Step 1's fix,
        // findNotesMatch's "already flagged" branch picked via
        // `unmatched.first(where: { $0.isNotes })` -- lowest sortOrder wins, no evidence
        // check. The orphan below sits at BOTH the lowest sortOrder among the two
        // isNotes rows AND exactly at the header's parsed position, so both the old
        // lowest-sortOrder-first pick and a naive pure-proximity pick would wrongly
        // choose it. Only the live row's title actually matches the header, so
        // bestFlaggedCandidate must prefer it despite being farther away and having the
        // higher sortOrder.
        //
        // Now that the loser is swept via `.deleteDuplicate` (survivor-data-preservation
        // fix), this test can directly assert what happens to its real status/tags/
        // wordGoal, instead of only proving its id is never handed to a delete: the live
        // row's OWN status/tags (both real, non-default) must win untouched, while its
        // wordGoal is deliberately left at Section's true default (nil) so the orphan's
        // real wordGoal has something to migrate onto.
        let headers = [
            makeHeader(position: 0, title: "Notes", isNotes: true)
        ]
        let dbSections = [
            makeSection(
                id: "notesOrphan", sortOrder: 0, title: "Old Scratch Notes", isNotes: true,
                status: .final_, tags: ["stale"], wordGoal: 100
            ),
            Section(
                id: "notesLive", projectId: projectId, sortOrder: 5, headerLevel: 2,
                isNotes: true, title: "Notes", status: .writing, tags: ["current"]
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deleteDuplicates = changes.compactMap { change -> DeleteDuplicateChange? in
            if case .deleteDuplicate(let loserId, let survivorId, let updates) = change {
                return DeleteDuplicateChange(loserId: loserId, survivorId: survivorId, updates: updates)
            }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }

        #expect(deleteDuplicates.count == 1, "Orphan (no title/content evidence) must be swept via .deleteDuplicate, not the live row")
        if let migration = deleteDuplicates.first {
            #expect(migration.loserId == "notesOrphan")
            #expect(migration.survivorId == "notesLive")
            #expect(migration.updates.status == nil, "Live row's own status (.writing) wins untouched, not the orphan's .final_")
            #expect(migration.updates.tags == nil, "Live row's own tags win untouched, not the orphan's")
            #expect(migration.updates.wordGoal == 100, "Live row had no wordGoal of its own, so the orphan's real one migrates")
        }

        let liveUpdate = updates.first { $0.0 == "notesLive" }
        #expect(liveUpdate != nil, "Live row (title-matched) must survive matched")
        if let liveUpdate {
            #expect(liveUpdate.1.title == nil, "Live row's title is unchanged — no spurious title update")
        }
    }

    @Test("Stale earlier Bibliography orphan loses to the evidence-bearing row, and its real data migrates")
    func staleEarlierBibliographyOrphanLosesToEvidenceBearingRow() {
        // Mirror of staleEarlierNotesOrphanLosesToEvidenceBearingRow for isBibliography.
        let headers = [
            makeHeader(position: 0, title: "References", isBibliography: true)
        ]
        let dbSections = [
            makeSection(
                id: "bibOrphan", sortOrder: 0, title: "Old Scratch Bibliography", isBibliography: true,
                status: .final_, tags: ["stale"], wordGoal: 100
            ),
            Section(
                id: "bibLive", projectId: projectId, sortOrder: 5, headerLevel: 2,
                isBibliography: true, title: "References", status: .writing, tags: ["current"]
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deleteDuplicates = changes.compactMap { change -> DeleteDuplicateChange? in
            if case .deleteDuplicate(let loserId, let survivorId, let updates) = change {
                return DeleteDuplicateChange(loserId: loserId, survivorId: survivorId, updates: updates)
            }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }

        #expect(deleteDuplicates.count == 1, "Orphan (no title/content evidence) must be swept via .deleteDuplicate, not the live row")
        if let migration = deleteDuplicates.first {
            #expect(migration.loserId == "bibOrphan")
            #expect(migration.survivorId == "bibLive")
            #expect(migration.updates.status == nil, "Live row's own status (.writing) wins untouched, not the orphan's .final_")
            #expect(migration.updates.tags == nil, "Live row's own tags win untouched, not the orphan's")
            #expect(migration.updates.wordGoal == 100, "Live row had no wordGoal of its own, so the orphan's real one migrates")
        }

        let liveUpdate = updates.first { $0.0 == "bibLive" }
        #expect(liveUpdate != nil, "Live row (title-matched) must survive matched")
        if let liveUpdate {
            #expect(liveUpdate.1.title == nil, "Live row's title is unchanged — no spurious title update")
        }
    }

}
