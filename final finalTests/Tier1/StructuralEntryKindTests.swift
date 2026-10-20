//
//  StructuralEntryKindTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, plan U1): which timeline entries are "editor-first". An editor-first entry has no snapshot id of its own (its
//  background job writes the snapshot onto the entry's slot), and every switch that routes an entry (the slot lookup, eviction,
//  `replaceTopOfUndoStack`, the slow undo) reads `isEditorFirst`. A drag-reorder in Rich Text is recorded this way now.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("StructuralEntry kinds — editor-first or not")
@MainActor
struct StructuralEntryKindTests {

    // U1: a reorder recorded without a snapshot id is editor-first (the new road); one recorded WITH a snapshot id is the old
    // whole-document reorder (Markdown mode, zoomed, a fallback), which keeps the snapshot-id undo.
    @Test("reorderWithoutSnapshotIdIsEditorFirst")
    func reorderWithoutSnapshotIdIsEditorFirst() {
        let editorFirst = StructuralEntry(id: UUID(), kind: .sectionReorder, title: "Reorder Sections", undoSnapshotId: nil)
        #expect(editorFirst.isEditorFirst, "a reorder without a snapshot id was not recognised as editor-first")

        let old = StructuralEntry(id: UUID(), kind: .sectionReorder, title: "Reorder Sections", undoSnapshotId: "snapshot-1")
        #expect(!old.isEditorFirst, "a reorder that carries its own snapshot id is the old whole-document reorder")
    }
}
