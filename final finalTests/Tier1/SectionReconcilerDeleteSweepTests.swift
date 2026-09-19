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
// swiftlint:disable:next type_body_length
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

    // MARK: - Flagged-Row Precedence and Sweep Invariants

    @Test("Bibliography and Notes rows in range are neither stolen nor swept")
    func bibliographyAndNotesRowsInRangeAreNeitherStolenNorSwept() {
        // NON-DISCRIMINATING, and traced as such: pre-fix `[0]` claims bRow via (a), `[1]`
        // finds no candidate because flagged rows are excluded from the ordinary pool, and
        // `[2]` claims nRow via (a) — `insert("Middle", 1)` only, zero updates, zero deletes,
        // in both worlds. Its value is pinning the sweep invariants under the new pass order:
        // no flagged row deleted, no flag flip, no spurious update. No change is emitted for
        // either flagged row because the headers are byte-identical to their rows and neither
        // flag needs flipping.
        let bibContent = "## References\nReal references."
        let notesContent = "## Notes\nReal notes."
        let headers = [
            makeHeader(position: 0, title: "References", level: 1, markdownContent: bibContent,
                       isBibliography: true),
            makeHeader(position: 1, title: "Middle", markdownContent: "## Middle\nMiddle body."),
            makeHeader(position: 2, title: "Notes", level: 1, markdownContent: notesContent,
                       isNotes: true)
        ]
        let dbSections = [
            makeSection(id: "bRow", sortOrder: 0, title: "References", headerLevel: 1,
                        isBibliography: true, markdownContent: bibContent),
            makeSection(id: "nRow", sortOrder: 2, title: "Notes", headerLevel: 1,
                        isNotes: true, markdownContent: notesContent)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        #expect(updates.isEmpty, "Both flagged rows already byte-match, and no flag flip occurred")
        #expect(deletedIds.isEmpty, "No flagged row may be swept")
        #expect(inserts.map(\.title) == ["Middle"], "Only the ordinary header inserts")
        #expect(inserts.map(\.sortOrder) == [1], "Its insert lands at its own index")
    }

    @Test("Flagged proximity grab no longer pre-empts an ordinary title match")
    func flaggedProximityGrabNoLongerPreemptsOrdinaryTitleMatch() throws {
        // Pre-fix the flagged header at index 0 ran first in the header-major loop: (a) found
        // no flagged row, (b) no row at position 0, (c) `|3 - 0| == 3` → rUser gate-passed by
        // title, so it claimed the row AND flipped the flag. Post-fix every ordinary header's
        // Pass 2 title+level match runs before the flagged block's (b)/(c), so the ordinary
        // header wins. `[1]`'s position (5) is deliberately decoupled from its array index so
        // it must arrive through Pass 2 rather than Pass 1.
        //
        // Deliberate fixture decoupling (C7): production always has `position == index`, so the
        // `[1]`-at-position-5 shape is synthetic. It is kept because it is what forces the
        // ordinary header's claim through Pass 2 — the pass whose ordering relative to the
        // flagged block is the behavior this pin exists to disclose. With contiguous positions
        // the ordinary header would sit at position 1, no row would be there either, and the
        // test would still exercise Pass 2; the decoupling makes the intent unambiguous.
        let sharedContent = "## References\nReal references chapter."
        let headers = [
            makeHeader(position: 0, title: "References", level: 1, markdownContent: sharedContent,
                       isBibliography: true),
            makeHeader(position: 5, title: "References", level: 1, markdownContent: sharedContent)
        ]
        let dbSections = [
            makeSection(id: "rUser", sortOrder: 3, title: "References", headerLevel: 1,
                        markdownContent: sharedContent)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let rUserUpdate = try #require(updates.first { $0.0 == "rUser" },
                                       "The ordinary header must claim rUser in Pass 2")
        #expect(rUserUpdate.1.isBibliography == nil, "rUser must NOT be flipped into the bibliography row")
        #expect(rUserUpdate.1.title == nil, "rUser keeps its own title")
        #expect(rUserUpdate.1.sortOrder == 1, "rUser moves to the ordinary header's index")
        #expect(inserts.first?.isBibliography == true, "The flagged header inserts a real bibliography row")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    @Test("Flagged title grab within range beats an earlier ordinary content match")
    func flaggedTitleGrabWithinRangeBeatsEarlierOrdinaryContentMatch() throws {
        // The production-visible consequence of the binding pass order: the flagged header's
        // (c) has the SAME evidence shape as ordinary Pass 3a, so the flagged header wins the
        // ±3 tie and converts the nearby ordinary row into the machine bibliography row while
        // the ordinary header inserts a duplicate. The old array order gave no protection here
        // anyway — the flagged heading is normally last in the document, so it ran last.
        //
        // `[0]` cannot title-match r (so Pass 2 cannot take it and it must reach 3a on
        // content evidence), while `[1]`'s (c) gate-passes on title inside ±3: a genuine tie.
        let sharedContent = "## References\nOriginal references body."
        let headers = [
            makeHeader(position: 0, title: "Different Title", level: 1, markdownContent: sharedContent),
            makeHeader(position: 1, title: "References", level: 1, markdownContent: sharedContent,
                       isBibliography: true)
        ]
        let dbSections = [
            makeSection(id: "r", sortOrder: 2, title: "References", headerLevel: 1,
                        markdownContent: sharedContent)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let rUpdate = try #require(updates.first { $0.0 == "r" },
                                   "r must be claimed by the flagged header's in-range title match")
        #expect(rUpdate.1.isBibliography == true, "r is converted into the bibliography row")
        #expect(rUpdate.1.title == nil, "r keeps its own title")
        #expect(rUpdate.1.sortOrder == 1, "r moves to the flagged header's index")
        #expect(inserts.map(\.title) == ["Different Title"],
                "The ordinary header inserts — it lost the ±3 tie on evidence shape")
        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at its own index")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

}
