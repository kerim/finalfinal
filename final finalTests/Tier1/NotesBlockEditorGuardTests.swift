//
//  NotesBlockEditorGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the applyBlockChangesFromEditor safety net that stops a stale editor diff
//  from silently reverting or destroying a machine-managed Notes (footnote definition) or
//  Bibliography row. reconcileNotesBlocks renames footnote labels in place, keeping the
//  same block id, so a stale pre-rename JS view can still match a renamed row by id and
//  revert or delete it via the forced flush in handleFootnoteInsertedImmediate.
//

import Testing
import Foundation
@testable import final_final

@Suite("Notes/Bibliography editor-diff guard — Tier 1: Silent Killers")
struct NotesBlockEditorGuardTests {

    @Test("Stale rename-revert update is rejected (the core race, at unit level)")
    func staleRenameRevertUpdateIsRejected() throws {
        let seed = """
        Body[^2].

        # Notes

        [^2]: First real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let notesBlock = try #require(
            try TestFixtureFactory.fetchBlocks(from: db)
                .first { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]:") }
        )

        // JS's stale pre-rename view: the row is really [^2] now, but the diff still thinks
        // it's [^1] (as if reconcileNotesBlocks renamed it in place after JS last saw it).
        let changes = BlockChanges(updates: [
            BlockUpdate(
                id: notesBlock.id,
                textContent: "First real text.",
                markdownFragment: "[^1]: First real text.",
                headingLevel: nil
            )
        ])

        _ = try db.applyBlockChangesFromEditor(changes, for: projectId)

        let after = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == notesBlock.id })
        #expect(
            after.markdownFragment == "[^2]: First real text.",
            "The stale label-reverting update must be rejected — the row must still read [^2]"
        )
    }

    @Test("Delete of an isNotes row via editor diff is rejected")
    func deleteOfNotesRowViaEditorDiffIsRejected() throws {
        let seed = """
        Body[^2].

        # Notes

        [^2]: First real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let notesBlock = try #require(
            try TestFixtureFactory.fetchBlocks(from: db)
                .first { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]:") }
        )

        let changes = BlockChanges(deletes: [notesBlock.id])
        _ = try db.applyBlockChangesFromEditor(changes, for: projectId)

        let survivor = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == notesBlock.id }
        #expect(survivor != nil, "A delete of an isNotes row via the editor diff must be rejected")
    }

    @Test("Legitimate same-label text edit IS applied (guard is narrow, not over-blocking)")
    func legitimateSameLabelEditIsApplied() throws {
        let seed = """
        Body[^2].

        # Notes

        [^2]: old text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let notesBlock = try #require(
            try TestFixtureFactory.fetchBlocks(from: db)
                .first { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]:") }
        )

        // Same label ("2"), only the definition text changed — a genuine user edit that must
        // continue to reach the DB through this exact path.
        let changes = BlockChanges(updates: [
            BlockUpdate(
                id: notesBlock.id,
                textContent: "new text.",
                markdownFragment: "[^2]: new text.",
                headingLevel: nil
            )
        ])

        _ = try db.applyBlockChangesFromEditor(changes, for: projectId)

        let after = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == notesBlock.id })
        #expect(
            after.markdownFragment == "[^2]: new text.",
            "A label-preserving definition-text edit must be applied, not rejected"
        )
    }

    @Test("Delete of an isBibliography row via editor diff is rejected")
    func deleteOfBibliographyRowViaEditorDiffIsRejected() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Title\n\nBody text.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        var bibBlock = Block(
            projectId: projectId,
            sortOrder: 1000,
            blockType: .paragraph,
            textContent: "Smith, J. (2020). Example reference.",
            markdownFragment: "Smith, J. (2020). Example reference.",
            isBibliography: true
        )
        try db.dbWriter.write { database in
            try bibBlock.insert(database)
        }

        let changes = BlockChanges(deletes: [bibBlock.id])
        _ = try db.applyBlockChangesFromEditor(changes, for: projectId)

        let survivor = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == bibBlock.id }
        #expect(survivor != nil, "A delete of an isBibliography row via the editor diff must be rejected")
    }

    @Test("Control — normal paragraph still updates and deletes")
    func normalParagraphStillUpdatesAndDeletes() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Title\n\nOriginal paragraph text.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let paragraph = try #require(
            try TestFixtureFactory.fetchBlocks(from: db).first { $0.blockType == .paragraph }
        )

        // Update first — ordinary content must still change.
        let updateChanges = BlockChanges(updates: [
            BlockUpdate(
                id: paragraph.id,
                textContent: "Edited paragraph text.",
                markdownFragment: "Edited paragraph text.",
                headingLevel: nil
            )
        ])
        _ = try db.applyBlockChangesFromEditor(updateChanges, for: projectId)

        let afterUpdate = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == paragraph.id })
        #expect(afterUpdate.markdownFragment == "Edited paragraph text.", "Ordinary paragraph updates must still apply")

        // Then delete — ordinary content must still be removable.
        let deleteChanges = BlockChanges(deletes: [paragraph.id])
        _ = try db.applyBlockChangesFromEditor(deleteChanges, for: projectId)

        let afterDelete = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == paragraph.id }
        #expect(afterDelete == nil, "Ordinary paragraph deletes must still apply — the guards must not over-block")
    }
}
