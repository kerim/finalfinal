//
//  MarkdownEditorFirstSwitch.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5: the switch of the Markdown editor-first
//  Delete Section (`StructuralUndoController.performMarkdownEditorFirstDelete`, StructuralUndoController+MarkdownEditorFirst.swift).
//
//  ROUND 7b FLIPPED THE DEFAULT TO ON. The Cmd-Z and Cmd-Shift-Z routes a Markdown entry needs are in (the quick undo and redo,
//  StructuralUndoController+MarkdownQuickUndo.swift; the queued slow route, StructuralUndoController+MarkdownSlowUndo.swift; the held
//  presses' Swift side, CodeMirrorCoordinator+MessageDispatch.swift), so a Markdown Delete Section is recorded editor-first and Cmd-Z
//  knows how to take it back. With the switch off `performMarkdownEditorFirstDelete` returns nil at its first line, before it touches
//  the hold, the rebuild stamp or the page, and the delete is the old body, step for step; the switch stays as the one place to turn the
//  feature off. Duplicate Section, the drag-reorder and the three Version History restores in Markdown mode are NOT affected by it:
//  their clicks keep the old body (slices 2 to 4 are not built); only their Cmd-Z and Cmd-Shift-Z take the new queued route.
//  Tests that need the old delete set it false and put `productionDefault` back (the rig's `restore()` does).
//

import Foundation

@MainActor
enum MarkdownEditorFirstSwitch {
    /// What a fresh process starts with.
    static let productionDefault = true

    /// Whether Delete Section in Markdown mode runs editor-first.
    static var enabled = productionDefault
}
