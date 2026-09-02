//
//  FootnoteSyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for footnote sync: reference extraction, definition parsing,
//  and Notes section stripping. Lost footnote definitions corrupt documents.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Footnote Sync — Tier 1: Silent Killers")
struct FootnoteSyncTests {

    // MARK: - extractFootnoteRefs

    @Test("extractFootnoteRefs finds single ref")
    func extractFootnoteRefsSingleRef() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "Text[^1] more")
        #expect(refs == ["1"])
    }

    @Test("extractFootnoteRefs finds multiple refs in order")
    func extractFootnoteRefsMultipleRefs() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "A[^1] B[^2] C[^3]")
        #expect(refs == ["1", "2", "3"])
    }

    @Test("extractFootnoteRefs deduplicates repeated refs")
    func extractFootnoteRefsDeduplicates() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "A[^1] B[^1]")
        #expect(refs == ["1"])
    }

    @Test("extractFootnoteRefs excludes definitions")
    func extractFootnoteRefsExcludesDefinitions() {
        let markdown = """
        Text[^1] here.

        # Notes

        [^1]: This is a definition
        """
        let refs = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        #expect(refs == ["1"], "Should find the ref but not count the definition as a ref")
    }

    @Test("extractFootnoteRefs excludes refs in Notes section")
    func extractFootnoteRefsExcludesNotesSection() {
        let markdown = """
        Body text[^1] here.

        # Notes

        [^1]: Definition that mentions[^2] another ref
        """
        let refs = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        #expect(refs == ["1"], "Refs inside Notes section should be excluded")
    }

    // MARK: - extractFootnoteDefinitions

    @Test("extractFootnoteDefinitions parses single and multi-paragraph definitions")
    func extractFootnoteDefinitions() {
        let notesContent = """
        # Notes

        [^1]: Simple definition.

        [^2]: First paragraph.
            Second paragraph with 4-space indent.
        """
        let defs = FootnoteSyncService.extractFootnoteDefinitions(from: notesContent)
        #expect(defs["1"] == "Simple definition.")
        #expect(defs["2"]?.contains("First paragraph.") == true)
        #expect(defs["2"]?.contains("Second paragraph with 4-space indent.") == true)
    }

    // MARK: - stripNotesSection

    @Test("stripNotesSection removes Notes but preserves other headings")
    func stripNotesSectionRemovesNotesOnly() {
        let markdown = """
        # Intro

        Introduction text.

        # Notes

        [^1]: A definition.

        # References

        Some references.
        """
        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(stripped.contains("# Intro"), "Should preserve Intro heading")
        #expect(stripped.contains("Introduction text"), "Should preserve Intro content")
        #expect(!stripped.contains("# Notes"), "Should remove Notes heading")
        #expect(!stripped.contains("[^1]:"), "Should remove Notes content")
        #expect(stripped.contains("# References"), "Should preserve References heading")
        #expect(stripped.contains("Some references"), "Should preserve References content")
    }

    // MARK: - Immediate/debounced race (duplicate definition guard)

    @Test("Stale debounced rebuild after an immediate insertion is superseded (no lost/duplicate definition)")
    @MainActor
    func immediateInsertionSupersedesStaleDebounce() async throws {
        // Seed a document whose Notes section already has one real definition ([^1]).
        let seed = """
        Body text[^1] here.

        # Notes

        [^1]: Real definition one.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Capture [^1]'s block id before anything runs — the upsert must never delete
        // and recreate a label it doesn't touch.
        let originalOneId = try #require(
            try TestFixtureFactory.fetchBlocks(from: db)
                .first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }
        ).id

        // A debounced rebuild was scheduled with the pre-insertion snapshot (generation 0, refs=["1"]).

        // 1. Immediate insertion of [^2] (as if the user ran /footnote). Rebuilds Notes to
        //    [^1] real + [^2] empty, and bumps syncGeneration 0 -> 1.
        service.handleImmediateInsertion(label: "2", projectId: projectId)

        // 2. The stale debounced rebuild now fires. It must bail because the immediate
        //    insertion superseded it. Without the fix it deletes/empties the fresh [^2].
        await service.performFootnoteUpdate(
            refs: ["1"], projectId: projectId, fullContent: seed, scheduledGeneration: 0
        )

        // 3. DB must hold exactly two definition blocks: [^1] (real) and [^2] (empty placeholder),
        //    with no duplicate and no data loss.
        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let frags = defs.map(\.markdownFragment)

        #expect(defs.count == 2, "Expected exactly [^1] and [^2]; got \(frags)")
        #expect(frags.filter { $0.hasPrefix("[^1]:") }.count == 1, "Exactly one [^1] block")
        #expect(frags.filter { $0.hasPrefix("[^2]:") }.count == 1, "Exactly one [^2] block (not destroyed)")
        #expect(frags.contains { $0.contains("Real definition one.") }, "[^1] real text preserved")

        // 4. [^1] must be the SAME row throughout — proves handleImmediateInsertion no
        //    longer delete-and-recreates labels it never touched.
        let survivingOne = defs.first { $0.markdownFragment.hasPrefix("[^1]:") }
        #expect(survivingOne?.id == originalOneId, "[^1] must keep its original block id")
    }

    @Test("A current-generation debounced rebuild still runs (guard does not over-block)")
    @MainActor
    func currentGenerationDebounceStillRuns() async throws {
        let seed = """
        A[^1] B[^2].

        # Notes

        [^1]: First.

        [^2]: Second.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // No immediate insertion happened, so the debounce's captured generation (0) still matches.
        await service.performFootnoteUpdate(
            refs: ["1", "2"], projectId: projectId, fullContent: seed, scheduledGeneration: 0
        )

        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(defs.count == 2, "Legitimate debounced rebuild must still produce both definitions")
    }

    // MARK: - reconcileNotesBlocks (per-label-safe upsert)

    @Test("reconcileNotesBlocks leaves unrelated labels byte-identical (same id, same updatedAt)")
    @MainActor
    func reconcileNotesBlocksLeavesUnrelatedLabelsUntouched() throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })

        // Append a brand-new [^3] — no rename needed, so [^1] and [^2] are never
        // fetched-for-write.
        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(
                db: database, projectId: projectId, targetRefs: ["1", "2", "3"]
            )
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 3, "Expected [^1], [^2] (untouched) plus new [^3]")

        for (id, beforeBlock) in beforeById {
            let afterBlock = after.first { $0.id == id }
            #expect(afterBlock != nil, "Untouched block \(id) must still exist under the same id")
            #expect(
                afterBlock?.updatedAt == beforeBlock.updatedAt,
                "Untouched block \(id) must keep its original updatedAt — proves zero writes"
            )
            #expect(
                afterBlock?.markdownFragment == beforeBlock.markdownFragment,
                "Untouched block \(id) must keep its original text"
            )
        }

        #expect(after.contains { $0.markdownFragment.hasPrefix("[^3]:") }, "New [^3] block must be inserted")
    }

    @Test("handleImmediateInsertion preserves block identity and text across a rename")
    @MainActor
    func handleImmediateInsertionPreservesIdentityAcrossRename() throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let originalOne = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let originalTwo = try #require(before.first { $0.markdownFragment.hasPrefix("[^2]:") })

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // JS computed pivot "1" — inserting a new footnote before both existing ones
        // forces 1->2, 2->3.
        service.handleImmediateInsertion(label: "1", projectId: projectId)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 3, "Expected [^1] (new, empty), [^2] (was [^1]), [^3] (was [^2])")

        let renamedOne = after.first { $0.id == originalOne.id }
        let renamedTwo = after.first { $0.id == originalTwo.id }

        #expect(
            renamedOne?.markdownFragment == "[^2]: First real text.",
            "Original [^1] block survives rename to [^2] under the same id, with its original text intact"
        )
        #expect(
            renamedTwo?.markdownFragment == "[^3]: Second real text.",
            "Original [^2] block survives rename to [^3] under the same id, with its original text intact"
        )

        let newBlock = try #require(after.first { $0.markdownFragment.hasPrefix("[^1]:") })
        #expect(
            newBlock.id != originalOne.id && newBlock.id != originalTwo.id,
            "The new [^1] placeholder is a genuinely new row, not a reused id"
        )
    }

    // MARK: - E6 (Stage E): handleImmediateInsertion's returned blockId is the PIVOT's row,
    // not just any row reconcileNotesBlocks touched in the same call.
    //
    // Same rename-shift scenario as handleImmediateInsertionPreservesIdentityAcrossRename
    // above (both existing definitions get renamed in the same reconciliation pass that
    // inserts the new one), but asserts on the RETURN VALUE this time. This is the exact
    // seam Stage D's diagnostic logs showed working only by label-search luck: before E1,
    // reconcileNotesBlocks's step-6 insert id was discarded entirely, so the cursor-placement
    // notification had no way to name a row at all -- E1 makes it a guarantee by returning
    // the id keyed by label, and this test proves handleImmediateInsertion picks the PIVOT's
    // key out of that map (String(pivot)), not e.g. the first/any entry, and never one of the
    // renamed (pre-existing, real-text) rows that were also written to in this same call.
    @Test("handleImmediateInsertion returns the block id of the label the user actually inserted, not a renamed pre-existing row")
    @MainActor
    func handleImmediateInsertionReturnsPivotBlockIdNotRenamedRow() throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let originalOne = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let originalTwo = try #require(before.first { $0.markdownFragment.hasPrefix("[^2]:") })

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Pivot "1": both pre-existing definitions get renamed (1->2, 2->3) in the SAME
        // reconciliation pass that inserts the new blank [^1] row -- exactly the shape where
        // "any row this call touched" and "the row the user actually inserted" diverge.
        let insertedBlockId = service.handleImmediateInsertion(label: "1", projectId: projectId)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let newBlock = try #require(after.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let renamedOne = try #require(after.first { $0.id == originalOne.id }) // now "[^2]:"
        let renamedTwo = try #require(after.first { $0.id == originalTwo.id }) // now "[^3]:"

        #expect(insertedBlockId == newBlock.id, "Must name the genuinely-new [^1] row")
        #expect(
            insertedBlockId != renamedOne.id && insertedBlockId != renamedTwo.id,
            "Must NOT name either renamed pre-existing row, even though reconcileNotesBlocks wrote to them in the same call"
        )
        #expect(newBlock.markdownFragment == "[^1]: ", "Sanity: the named row really is the new blank definition")
        #expect(renamedOne.markdownFragment == "[^2]: First real text.")
        #expect(renamedTwo.markdownFragment == "[^3]: Second real text.")
    }

    @Test("handleImmediateInsertion returns the correct pivot id on a pure append (no renames in play)")
    @MainActor
    func handleImmediateInsertionReturnsPivotBlockIdOnAppend() throws {
        let seed = """
        Body[^1].

        # Notes

        [^1]: Only definition.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Pivot "2": appends after the existing [^1], nothing to rename.
        let insertedBlockId = try #require(service.handleImmediateInsertion(label: "2", projectId: projectId))

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let newBlock = try #require(after.first { $0.markdownFragment.hasPrefix("[^2]:") })
        let untouchedOne = try #require(after.first { $0.markdownFragment.hasPrefix("[^1]:") })

        #expect(insertedBlockId == newBlock.id)
        #expect(insertedBlockId != untouchedOne.id)
    }

    @Test("reconcileNotesBlocks resolves a mixed insert+delete+rename in a single call")
    @MainActor
    func reconcileNotesBlocksHandlesMixedInsertDeleteRenameInOneCall() throws {
        let seed = """
        Body[^1] and[^2] and[^3] and[^5].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.

        [^3]: Third real text.

        [^5]: Fifth real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let originalOne = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let originalTwo = try #require(before.first { $0.markdownFragment.hasPrefix("[^2]:") })
        let originalThree = try #require(before.first { $0.markdownFragment.hasPrefix("[^3]:") })
        let originalFive = try #require(before.first { $0.markdownFragment.hasPrefix("[^5]:") })

        // A single reconcile call that simultaneously: renames [^2]->[^4], deletes [^5]
        // (no longer in the target set), inserts a brand-new [^6], and leaves [^1]
        // completely untouched.
        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(
                db: database,
                projectId: projectId,
                targetRefs: ["1", "3", "4", "6"],
                renameMap: ["2": "4"]
            )
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 4, "Expected [^1], [^3], [^4] (was [^2]), [^6] (new)")

        // Untouched: [^1] was never in the rename map, delete set, or insert set — must
        // be the exact same row, never fetched-for-write.
        let untouchedOne = after.first { $0.id == originalOne.id }
        #expect(untouchedOne?.updatedAt == originalOne.updatedAt, "[^1] must keep its original updatedAt — proves zero writes")
        #expect(untouchedOne?.markdownFragment == originalOne.markdownFragment, "[^1] must keep its original text untouched")

        // Renamed: [^2] survives as [^4] under the same block id, with its original text
        // carried forward.
        let renamedTwo = after.first { $0.id == originalTwo.id }
        #expect(renamedTwo?.markdownFragment == "[^4]: Second real text.", "Original [^2] block survives rename to [^4] with its text intact")

        // Untouched-content: [^3] keeps its id and text even though the rename shuffling
        // [^2]->[^4] past it may bump its sortOrder/updatedAt during renormalization.
        let survivingThree = after.first { $0.id == originalThree.id }
        #expect(survivingThree?.markdownFragment == originalThree.markdownFragment, "[^3] keeps its original label and text")

        // Deleted: [^5] is gone entirely, no longer present under its old id or label.
        #expect(!after.contains { $0.id == originalFive.id }, "[^5] block must be deleted")
        #expect(!after.contains { $0.markdownFragment.hasPrefix("[^5]:") }, "No block should carry the [^5] label anymore")

        // Inserted: [^6] is a genuinely new row (not a reused id) with the expected blank
        // placeholder text.
        let newSix = try #require(after.first { $0.markdownFragment.hasPrefix("[^6]:") })
        #expect(newSix.markdownFragment == "[^6]: ", "New [^6] gets the default blank placeholder text")
        #expect(
            ![originalOne.id, originalTwo.id, originalThree.id, originalFive.id].contains(newSix.id),
            "The new [^6] placeholder is a genuinely new row, not a reused id"
        )
    }
}

// MARK: - Continuation ownership (multi-paragraph footnote fix)
//
// Split into its own extension (rather than growing the primary struct body further) to
// stay under swiftlint's type_body_length threshold — SwiftLint counts an extension's body
// separately from the type's own declaration.
extension FootnoteSyncTests {
    @Test("reconcileNotesBlocks: continuation ownership survives a rename of its owning label")
    @MainActor
    func reconcileNotesBlocksContinuationOwnershipSurvivesRename() throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First definition.

        [^2]: Second definition.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let seeded = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let def1 = try #require(seeded.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let def2 = try #require(seeded.first { $0.markdownFragment.hasPrefix("[^2]:") })

        // Manually seed a continuation paragraph directly after each definition -- exactly
        // the shape a real reparse produces for a multi-paragraph footnote (isNotes: true,
        // no "[^N]:" prefix of its own). Constructed directly (bypassing the insert-path and
        // replace-path fixes) so this test exercises ONLY reconcileNotesBlocks' own
        // ownership logic, per this task's independence requirement.
        var continuationOfOne = Block(
            projectId: projectId, sortOrder: def1.sortOrder + 0.1, blockType: .paragraph,
            textContent: "Continuation that belongs to the first footnote.",
            markdownFragment: "Continuation that belongs to the first footnote.",
            isNotes: true
        )
        var continuationOfTwo = Block(
            projectId: projectId, sortOrder: def2.sortOrder + 0.1, blockType: .paragraph,
            textContent: "Continuation that belongs to the second footnote.",
            markdownFragment: "Continuation that belongs to the second footnote.",
            isNotes: true
        )
        try db.write { database in
            try continuationOfOne.insert(database)
            try continuationOfTwo.insert(database)
        }
        let continuationOfOneId = continuationOfOne.id
        let continuationOfTwoId = continuationOfTwo.id

        // Rename BOTH labels in one call -- the load-bearing scenario: ownership must
        // survive even when both owning definitions move to new labels simultaneously (an
        // overlapping shift, same as reconcileNotesBlocks' other rename tests).
        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(
                db: database, projectId: projectId,
                targetRefs: ["3", "4"], renameMap: ["1": "3", "2": "4"]
            )
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes }
            .sorted { $0.sortOrder < $1.sortOrder }

        // Neither continuation was deleted by the renamed-label reconciliation.
        #expect(after.contains { $0.id == continuationOfOneId }, "Continuation of [^1] must survive the rename")
        #expect(after.contains { $0.id == continuationOfTwoId }, "Continuation of [^2] must survive the rename")

        // Ownership survived the rename: each continuation must still sit IMMEDIATELY after
        // its (renamed) owning definition, in final sortOrder order -- proving `sortOrder`
        // positional adjacency (the load-bearing assumption) held through the rename.
        let renamedThreeIndex = try #require(after.firstIndex { $0.markdownFragment.hasPrefix("[^3]:") })
        let renamedFourIndex = try #require(after.firstIndex { $0.markdownFragment.hasPrefix("[^4]:") })

        #expect(renamedThreeIndex + 1 < after.count)
        if renamedThreeIndex + 1 < after.count {
            #expect(
                after[renamedThreeIndex + 1].id == continuationOfOneId,
                "The continuation that belonged to [^1] must still immediately follow it under its new label [^3]"
            )
        }

        #expect(renamedFourIndex + 1 < after.count)
        if renamedFourIndex + 1 < after.count {
            #expect(
                after[renamedFourIndex + 1].id == continuationOfTwoId,
                "The continuation that belonged to [^2] must still immediately follow it under its new label [^4]"
            )
        }
    }

    @Test("reconcileNotesBlocks cascade-delete never touches dual-flagged (isBibliography) rows")
    @MainActor
    func reconcileNotesBlocksCascadeDeleteExcludesBibliographyRows() throws {
        // A legacy shape: a heading whose configured bibliography-opening title collided
        // with "Notes" can leave bibliography entries flagged BOTH isNotes and
        // isBibliography (see docs/deferred/bibliography-heading-collision-ambiguity.md and
        // BlockParser.swift's independent inBibliographySection/inNotesSection tracking).
        // Hand-constructed directly (bypassing real parse/settings) to isolate exactly this
        // shape: a real footnote followed, in sortOrder, by dual-flagged rows that do NOT
        // parse as "[^N]:" -- exactly where an ownership walk with no isBibliography
        // exclusion would (wrongly) attribute them to the footnote as its continuations.
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        var notesHeading = Block(
            projectId: projectId, sortOrder: 1, blockType: .heading, textContent: "Notes",
            markdownFragment: "# Notes", headingLevel: 1, isNotes: true
        )
        var def1 = Block(
            projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "A real footnote.", markdownFragment: "[^1]: A real footnote.", isNotes: true
        )
        var bibEntry1 = Block(
            projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "Smith, J. (2023). A bibliography entry.",
            markdownFragment: "Smith, J. (2023). A bibliography entry.",
            isBibliography: true, isNotes: true
        )
        var bibEntry2 = Block(
            projectId: projectId, sortOrder: 4, blockType: .paragraph,
            textContent: "Jones, K. (2022). Another entry.",
            markdownFragment: "Jones, K. (2022). Another entry.",
            isBibliography: true, isNotes: true
        )
        try db.write { database in
            try notesHeading.insert(database)
            try def1.insert(database)
            try bibEntry1.insert(database)
            try bibEntry2.insert(database)
        }

        // Remove [^1] from the target set -- the user deleted its reference. Cascade-delete
        // must remove ONLY [^1]'s own row, never the bibliography entries sitting after it.
        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: [])
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(
            after.contains { $0.id == bibEntry1.id },
            "A dual-flagged bibliography entry must survive [^1]'s deletion -- it is never [^1]'s continuation"
        )
        #expect(
            after.contains { $0.id == bibEntry2.id },
            "A dual-flagged bibliography entry must survive [^1]'s deletion -- it is never [^1]'s continuation"
        )
        #expect(
            !after.contains { $0.id == def1.id },
            "[^1] itself must still be deleted -- it was correctly removed from the target set"
        )
    }

    @Test("A debounced rebuild with already-correct refs performs zero writes")
    @MainActor
    func debouncedUpdateNotesBlockIsNoOpWhenNothingChanged() async throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        let before = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isNotes }
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })

        // Refs already match the DB exactly (sequential, no renumbering needed) — a
        // debounced rebuild scheduled for this state must be a pure no-op at the write level.
        await service.performFootnoteUpdate(
            refs: ["1", "2"], projectId: projectId, fullContent: seed, scheduledGeneration: 0
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isNotes }
        #expect(after.count == before.count, "No blocks should be added or removed")
        for (id, beforeBlock) in beforeById {
            let afterBlock = after.first { $0.id == id }
            #expect(
                afterBlock?.updatedAt == beforeBlock.updatedAt,
                "Block \(id) must be untouched (same updatedAt) when nothing actually changed"
            )
        }
    }

    @Test("Guaranteed resync recovers a debounce that an unrelated immediate insertion silently cancelled")
    @MainActor
    func guaranteedResyncRunsUnrelatedDroppedDebounce() async throws {
        // Body already contains [^1] (defined) and a freshly pasted [^2] ref with no
        // definition yet — its debounce (refs=["1","2"]) hasn't fired.
        let seed = """
        Body[^1] and pasted[^2] ref.

        # Notes

        [^1]: Real definition one.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // 1. That paste would have scheduled a debounce for refs=["1","2"] at generation 0.
        //    Not simulated as a real Task here — the existing race tests already establish
        //    that a cancelled/stale debounce never reaches performFootnoteUpdate at all.

        // 2. Before it fires, an unrelated immediate insertion happens elsewhere in the
        //    live document. JS's live scan finds both [^1] and [^2] positioned before the
        //    cursor, so it computes pivot "3" (a pure append). This cancels the pending
        //    debounce and bumps syncGeneration — but handleImmediateInsertion only reads
        //    the DB's Notes blocks (which don't have [^2] yet), so its own delta creates
        //    [^3] without ever learning [^2] exists.
        let bodyAfterInsertion = """
        Body[^1] and pasted[^2] ref. New footnote[^3] too.

        # Notes

        [^1]: Real definition one.
        """
        service.handleImmediateInsertion(label: "3", projectId: projectId)

        let midway = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let midwayLabels = Set(midway.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(
            midwayLabels == Set(["1", "3"]),
            "handleImmediateInsertion's own delta knows nothing about [^2] — it's silently missing here without the fix"
        )

        // 3. Guaranteed resync: ContentView calls checkAndUpdateFootnotes again with the
        //    live document's fresh content once contentState returns to idle — this is the
        //    fix under test. Without it, nothing else re-triggers a check (onChange was
        //    suppressed for the whole immediate-insertion flow), so [^2] would stay missing
        //    forever.
        let refreshedRefs = FootnoteSyncService.extractFootnoteRefs(from: bodyAfterInsertion)
        service.checkAndUpdateFootnotes(
            footnoteRefs: refreshedRefs, projectId: projectId, fullContent: bodyAfterInsertion
        )
        // Drive the newly-scheduled debounce synchronously (avoids a real 3s sleep in the
        // test). scheduledGeneration 1 matches syncGeneration after the immediate insertion
        // above, exactly like the debounce checkAndUpdateFootnotes just scheduled.
        await service.performFootnoteUpdate(
            refs: refreshedRefs, projectId: projectId, fullContent: bodyAfterInsertion, scheduledGeneration: 1
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 3, "Expected exactly [^1], [^2], [^3] — no duplicates")
        let afterLabels = Set(after.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(afterLabels == Set(["1", "2", "3"]), "Guaranteed resync recovers the dropped [^2] entry")
    }
}
