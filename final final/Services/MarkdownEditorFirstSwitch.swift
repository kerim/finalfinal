//
//  MarkdownEditorFirstSwitch.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5: the switch of the Markdown editor-first
//  Delete Section (`StructuralUndoController.performMarkdownEditorFirstDelete`, StructuralUndoController+MarkdownEditorFirst.swift) and,
//  since slice 2, of the Markdown editor-first drag-reorder (`performMarkdownEditorFirstReorder`,
//  StructuralUndoController+MarkdownEditorFirstReorder.swift) and, since slice 3, of the Markdown editor-first Duplicate Section
//  (`performMarkdownEditorFirstDuplicate`, StructuralUndoController+MarkdownEditorFirstDuplicate.swift).
//
//  ROUND 7b FLIPPED THE DEFAULT TO ON. The Cmd-Z and Cmd-Shift-Z routes a Markdown entry needs are in (the quick undo and redo,
//  StructuralUndoController+MarkdownQuickUndo.swift; the queued slow route, StructuralUndoController+MarkdownSlowUndo.swift; the held
//  presses' Swift side, CodeMirrorCoordinator+MessageDispatch.swift), so a Markdown Delete Section is recorded editor-first and Cmd-Z
//  knows how to take it back. With the switch off `performMarkdownEditorFirstDelete` returns nil at its first line, before it touches
//  the hold, the rebuild stamp or the page, and the delete is the old body, step for step; the switch stays as the one place to turn the
//  feature off. `performMarkdownEditorFirstReorder` does the same: with the switch off a Markdown drag is the old whole-document body
//  (and bumps `structuralOutOfQueueGeneration`, which closes an earlier Delete's quick undo, as it always did). So does
//  `performMarkdownEditorFirstDuplicate`: with the switch off a Markdown Duplicate is the old whole-document body (which also bumps
//  `structuralOutOfQueueGeneration`). The three Version History restores in Markdown mode are NOT affected by it: their clicks keep
//  the old body (slice 4 is not built); only their Cmd-Z and Cmd-Shift-Z take the new queued route.
//  Tests that need the old delete set it false and put `productionDefault` back (the rig's `restore()` does).
//

import Foundation

@MainActor
enum MarkdownEditorFirstSwitch {
    /// What a fresh process starts with.
    static let productionDefault = true

    /// Whether Delete Section and the sidebar drag-reorder in Markdown mode run editor-first.
    static var enabled = productionDefault
}
