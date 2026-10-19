//
//  EditorFirstSectionRestoreFixtures.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-ii): what the two suites of the editor-first SECTION Version History restores share
//  (EditorFirstSectionRestoreTests.swift: the click, D8, parity; EditorFirstSectionRestoreUndoTests.swift: a failed job, the rebuild
//  guard, the quick undo and redo, the sidebar). Helpers on `QuickUndoFixtures`; nothing here is a test.
//
//  HOW A TEST SETS A RESTORE UP, as the window does. The `section` table is filled BEFORE the version is saved (a version holds the
//  table's sections), the document is changed afterwards, and the table is filled AGAIN when the test wants the window's picture to be
//  current (opening Version History syncs the table from the editor's text). A test about text typed "while the window was open" leaves
//  the table behind on purpose.
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension QuickUndoFixtures {

    /// A rig on `fourSections` with the section table filled and a version saved: the document the version holds is the one every test
    /// then changes.
    func makeSectionRigWithVersion() async throws -> (EditorFirstRig, Snapshot) {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        try await rig.fillSectionTable()
        return (rig, try saveVersion(rig))
    }

    /// The editor-first path ran: the editor was asked, and this rig's log holds no fallback or unresolved line.
    func restoreRanEditorFirst(_ rig: EditorFirstRig) -> Bool {
        !rig.scripts(containing: "replaceRangeEditorFirst").isEmpty && !rig.persistedLog.contains { $0.contains("[EF-STRUCT]") }
    }

    /// Unpins the undo-point copies the restores wrote (the pin set is process-wide).
    func unpinAllVersions(_ rig: EditorFirstRig) {
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) }
    }

    /// The text of every row, in document order.
    func documentTexts(_ rig: EditorFirstRig) throws -> [String] {
        try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
    }

    func blockWithText(_ rig: EditorFirstRig, _ text: String) throws -> Block {
        try #require(try rig.blocks().first { $0.textContent == text }, "no block with the text '\(text)'")
    }

    /// The heading or section break that heads the section `paragraph` belongs to (the nearest leader before it).
    func owningLeader(of paragraph: Block, in rig: EditorFirstRig) throws -> Block {
        try #require(try rig.blocks()
            .filter { ($0.blockType == .heading || $0.isPseudoSection) && !$0.isNotes && !$0.isBibliography && $0.sortOrder < paragraph.sortOrder }
            .max { $0.sortOrder < $1.sortOrder })
    }

    /// The alert a failed section restore raises (plan-v3 C4 wording for the section kinds, with the floor-item-5 sentence).
    static var failedSectionRestoreMessage: String {
        "The restore couldn't be saved, so the section is back as it was. Anything you typed into the restored text was removed with it."
    }

    /// Renames a heading row in the database only (text and Markdown), the way a heading typed since the last section sync looks to the
    /// plan. A plain (non-async) function: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    func renameHeadingInDatabase(_ rig: EditorFirstRig, _ id: String, to text: String) throws {
        _ = try rig.db.dbWriter.write { database in
            try Block.filter(key: id).updateAll(
                database, Block.Columns.textContent.set(to: text), Block.Columns.markdownFragment.set(to: "## " + text))
        }
    }
}
