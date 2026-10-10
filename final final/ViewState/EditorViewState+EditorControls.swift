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

    /// Markdown -> Rich Text, the text half of the switch (everything `handleEditorModeToggle` does before `toggleEditorMode()`): takes
    /// the text the Markdown editor holds NOW, strips the section anchors and the bibliography START marker, saves THAT to the database
    /// and hands it to Rich Text as `content`. The bibliography END marker (`BlockParser.bibliographyEndMarker`) is deliberately NOT
    /// stripped: it is what makes `BlockParser.parse` flag the bibliography heading and its entries, so a text without it stores them
    /// as ordinary blocks (`BibliographyOpeningSelector`, tier 2). `content` always carried it in Markdown mode (the page's push), and
    /// the Rich Text editor re-reads its document from the database right after (`onWebViewReady` sets `content` again).
    ///
    /// The text is `sourceContent`, not `content`. Just before the switch `CodeMirrorCoordinator.saveAndNotify` reads the page and
    /// refreshes `sourceContent` only; `content` (the same text with the anchors stripped) is refreshed by the page's own push, which
    /// runs 50 ms after the last key. Keys typed in that last 50 ms were therefore in `sourceContent` but not in `content`, and saving
    /// `content` stored the text without them. The incoming Rich Text editor loads its document from the database, so they were lost.
    ///
    /// `sourceContent` must hold the RAW document, hidden markers included: `saveAndNotify` reads it with
    /// `CodeMirrorEditor.Coordinator.preSwitchContentScript` (`getContentRaw()`), not `getContent()`, which strips the end marker (and
    /// the zoom-notes marker a zoomed flush splits the mini-Notes on) before this function ever sees the text. Reading `getContent()`
    /// here is what made every switch to Rich Text unflag the bibliography (2026-10-09, first seen in the VM runs of that day).
    func commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService) {
        let (cleaned, anchors) = sectionSyncService.extractSectionAnchors(markdown: sourceContent)
        DebugLog.log(.editor, "[SWITCH→MW] After extract: cleaned length=\(cleaned.count), anchors=\(anchors.count)")
        sourceAnchors = anchors
        // Also strip bibliography marker since Milkdown shouldn't see it
        let plainText = SectionSyncService.stripBibliographyMarker(from: cleaned)
        // `skipUnchangedWrite`: when the stored rows already are what this flush would store (no edit since the last save), nothing is
        // written, so every row keeps its id. A zoomed flush ignores the flag.
        flushContentToDatabase(overrideContent: plainText, skipUnchangedWrite: true)
        content = plainText
    }

    /// Request editor mode toggle - posts notification for current editor to save cursor first.
    /// Gates on debounce interval and blocks during data-sensitive transitions.
    func requestEditorModeToggle() {
        // Diagnostic (bug-fix round, ship-fix/fullsuite-round2): records that the request
        // reached this handler at all, plus the two values that decide whether either guard
        // below rejects it -- so a future regression (e.g. a click silently swallowed before it
        // ever reaches here) is distinguishable in the log from a guard genuinely rejecting a
        // request that did arrive.
        DebugLog.log(.editor, "[EditorModeToggle] requestEditorModeToggle called: canToggle=\(canToggleEditorMode) contentState=\(contentState)")
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

    /// The not-zoomed write of `flushContentToDatabase`: replace every row of the project with `blocks`.
    ///
    /// With `skipUnchangedWrite` (passed only by the Markdown <-> Rich Text switch) it uses `replaceBlocksIfChanged`: when the
    /// rows already stored are the rows this parse would store, nothing is written, every row keeps its id and the write counter
    /// is not bumped. Otherwise it is `replaceBlocks`, as it always was.
    func writeWholeDocumentRows(_ blocks: [Block], to db: ProjectDatabase, projectId: String, skipUnchangedWrite: Bool) throws {
        guard skipUnchangedWrite else {
            try db.replaceBlocks(blocks, for: projectId)
            return
        }
        let wrote = try db.replaceBlocksIfChanged(blocks, for: projectId)
        DebugLog.log(.zoom, "[FLUSH] switch flush: stored rows \(wrote ? "differed, wrote them" : "already matched, wrote nothing")")
    }

}
