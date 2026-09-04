//
//  EditorViewState+EditorControls.swift
//  final final
//

import SwiftUI

// MARK: - Editor Controls

extension EditorViewState {

    /// Resolve the active section ID from a block ID (Milkdown) or title (CodeMirror fallback)
    func resolveSectionId(blockId: String?, title: String) -> String? {
        if let blockId, sections.contains(where: { $0.id == blockId }) {
            return blockId
        }
        // Fallback: match by title (for CodeMirror or if blockId not found)
        return sections.first { $0.title == title }?.id
    }

    /// Guarded companion to `resolveSectionId`, and the only sanctioned way to write
    /// `currentSectionId` (bt t-fecee361). The editors report the caret's section on essentially
    /// every content push, and `@Observable` fires on any write, same value included -- so an
    /// unguarded assignment fired `currentSectionId`'s observation on every keystroke even when
    /// the resolved value hadn't actually changed. That wasted work reached
    /// `OutlineSidebarPane.body` (and its `OutlineSidebarRenderKey` construction), though the
    /// sidebar's own `.equatable()` gate already kept it from reaching the expensive
    /// `OutlineSidebar` render itself. (Measurement after this guard landed found
    /// `ContentView.body`'s actual per-keystroke redraw is driven by `editorState.content`
    /// changing -- a separate read in `ViewNotificationModifiers.swift`'s `.onChange(of:
    /// editorState.content)` -- not by `currentSectionId`, which does not change during a typing
    /// session; this guard does not fix that reported slowness, and is a correctness fix in its
    /// own right regardless -- `@Observable` firing on an identical write is always wasted work.)
    /// Two distinct shapes, both real, both handled here:
    ///
    ///  1. Same-value repeat: the caret hasn't left the section, `resolveSectionId` returns the id
    ///     already stored. Skip the write entirely.
    ///  2. Transient nil: `resolveSectionId` returns nil whenever `blockId` is absent from
    ///     `sections` AND no title matches -- which a mid-flight re-parse causes routinely, making
    ///     `currentSectionId` flap id -> nil -> id. Each of those IS a genuine value change, so
    ///     check 1 does not catch it. Treat an unresolvable caret as "we don't know yet" and keep
    ///     the previous id -- BUT ONLY IF that id is still a real section. If the previous id is
    ///     gone from `sections` (the user deleted the section the caret was in), nil is the honest
    ///     answer and gets written; pinning to a deleted id would highlight a card that no longer
    ///     exists in the sidebar and name a dead section in the status bar.
    func setCurrentSectionId(blockId: String?, title: String) {
        let resolved = resolveSectionId(blockId: blockId, title: title)
        if let resolved {
            if currentSectionId != resolved { currentSectionId = resolved }
            return
        }
        if let previous = currentSectionId, sections.contains(where: { $0.id == previous }) { return }
        if currentSectionId != nil { currentSectionId = nil }
    }

    func updateStats(words: Int, characters: Int) {
        wordCount = words
        characterCount = characters
    }

    /// Called by editor coordinators when the selection changes (empty text = deselect).
    func updateSelection(_ text: String) {
        selectedWordCount = text.isEmpty ? nil : MarkdownUtils.wordCount(for: text)
    }

    func scrollTo(offset: Int) {
        scrollToOffset = offset
    }

    func clearScrollRequest() {
        scrollToOffset = nil
        scrollToBlockId = nil
        scrollToAnnotationIndex = nil
    }

    func toggleEditorMode() {
        editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
    }

    /// Request editor mode toggle - posts notification for current editor to save cursor first.
    /// Gates on debounce interval and blocks during data-sensitive transitions.
    func requestEditorModeToggle() {
        guard canToggleEditorMode else { return }
        // Don't start the save chain during data-sensitive transitions. .structuralUndo
        // added in the Phase 3 review round: a mode toggle mid-sequence would reassign the
        // WebView StructuralUndoController is still operating on
        // (docs/architecture/unified-undo.md).
        switch contentState {
        case .projectSwitch, .zoomTransition, .structuralUndo:
            return
        default:
            break
        }
        lastToggleRequestTime = Date()  // Record at entry point to close the race window

        NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
    }

}
