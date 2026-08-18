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
        // WebView StructuralUndoController is still operating on (docs/plans/
        // patient-rewinding-clockwork.md §4.4).
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
