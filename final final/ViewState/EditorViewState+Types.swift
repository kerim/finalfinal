//
//  EditorViewState+Types.swift
//  final final
//

import SwiftUI

// MARK: - FocusedValue for Editor Toggle

struct EditorToggleKey: FocusedValueKey {
    typealias Value = EditorViewState
}

extension FocusedValues {
    var editorState: EditorViewState? {
        get { self[EditorToggleKey.self] }
        set { self[EditorToggleKey.self] = newValue }
    }
}

// MARK: - Focus Mode Snapshot

/// Captures the pre-focus-mode state for restoration when exiting focus mode.
/// This is session-only storage (not persisted) - if user quits while in focus mode,
/// a fresh snapshot is captured on next launch before applying focus mode.
struct FocusModeSnapshot: Sendable {
    let wasInFullScreen: Bool
    let outlineSidebarVisible: Bool?  // nil if not modified by focus mode
    let annotationPanelVisible: Bool? // nil if not modified by focus mode
    let annotationDisplayModes: [AnnotationType: AnnotationDisplayMode]? // nil if not modified
}

// MARK: - Editor Toggle Notifications
extension Notification.Name {
    /// Posted when editor mode toggle is requested - current editor should save cursor
    static let willToggleEditorMode = Notification.Name("willToggleEditorMode")
    /// Posted after cursor position is saved - toggle can proceed
    static let didSaveCursorPosition = Notification.Name("didSaveCursorPosition")
    /// Posted when sidebar requests scroll to a section
    static let scrollToSection = Notification.Name("scrollToSection")
    /// Posted when annotation display modes change - editors should update rendering
    static let annotationDisplayModesChanged = Notification.Name("annotationDisplayModesChanged")
    /// Posted to insert an annotation at the current cursor position (for keyboard shortcuts Cmd+Shift+T/C/R)
    static let insertAnnotation = Notification.Name("insertAnnotation")
    /// Posted to toggle highlight mark on selected text (Cmd+Shift+H)
    static let toggleHighlight = Notification.Name("toggleHighlight")
    /// Posted when citation library should be pushed to editor
    static let citationLibraryChanged = Notification.Name("citationLibraryChanged")
    /// Posted when the active CSL citation style changes (Export preferences: custom-style
    /// toggle or path edited) — editors should re-push the effective style (custom or
    /// bundled) to the live in-editor citeproc engine.
    static let citationStyleChanged = Notification.Name("citationStyleChanged")
    /// Posted when bibliography section content changes in the database
    static let bibliographySectionChanged = Notification.Name("bibliographySectionChanged")
    /// Posted when footnote notes section content changes in the database
    static let notesSectionChanged = Notification.Name("notesSectionChanged")
    /// Posted to insert a footnote at the current cursor position (Cmd+Shift+N)
    static let insertFootnote = Notification.Name("insertFootnote")
    /// Posted when footnote references need renumbering - editors should call renumberFootnotes(mapping)
    static let renumberFootnotes = Notification.Name("renumberFootnotes")
    /// Posted when editor appearance mode changes (WYSIWYG ↔ source) - Phase C dual-appearance
    static let editorAppearanceModeChanged = Notification.Name("editorAppearanceModeChanged")
    // MARK: - Formatting Command Notifications
    /// Posted to toggle bold on selected text
    static let toggleBold = Notification.Name("toggleBold")
    /// Posted to toggle italic on selected text
    static let toggleItalic = Notification.Name("toggleItalic")
    /// Posted to toggle strikethrough on selected text
    static let toggleStrikethrough = Notification.Name("toggleStrikethrough")
    /// Posted to set heading level (userInfo: ["level": Int], 0 = paragraph)
    static let setHeading = Notification.Name("setHeading")
    /// Posted to toggle bullet list on current block
    static let toggleBulletList = Notification.Name("toggleBulletList")
    /// Posted to toggle numbered list on current block
    static let toggleNumberList = Notification.Name("toggleNumberList")
    /// Posted to toggle blockquote on current block
    static let toggleBlockquote = Notification.Name("toggleBlockquote")
    /// Posted to toggle code block on current block
    static let toggleCodeBlock = Notification.Name("toggleCodeBlock")
    /// Posted to toggle inline code on selected text (Cmd+Option+`)
    static let toggleInlineCode = Notification.Name("toggleInlineCode")
    /// Posted to insert a link at the cursor
    static let insertLink = Notification.Name("insertLink")
    /// Posted to insert a brand-new citation at the current cursor position, opening the
    /// CAYW picker (Cmd+Shift+K keyboard shortcut + toolbar "Cite" button)
    static let insertCitation = Notification.Name("insertCitation")

    /// Posted when zoom-out completes and contentState is back to idle
    /// Used to trigger bibliography sync after zoom-out (citations added during zoom)
    static let didZoomOut = Notification.Name("didZoomOut")
    /// Posted when spellcheck is toggled on/off - editors should enable/disable spellcheck
    static let spellcheckStateChanged = Notification.Name("spellcheckStateChanged")
    /// Posted after BlockSyncService pushes content to JS — coordinator updates lastPushedContent
    static let blockSyncDidPushContent = Notification.Name("blockSyncDidPushContent")
    /// Posted when a footnote was inserted in JS — label captured via evaluateJavaScript completion
    static let footnoteInsertedImmediate = Notification.Name("footnoteInsertedImmediate")
    /// Posted to scroll the editor to a footnote definition [^N]: in the Notes section
    static let scrollToFootnoteDefinition = Notification.Name("scrollToFootnoteDefinition")
    /// Posted to set zoom footnote state in JS editors (isZoomMode + max label)
    static let setZoomFootnoteState = Notification.Name("setZoomFootnoteState")
    /// Posted to request image picker dialog (Insert > Image menu, Cmd+Shift+I)
    static let requestInsertImage = Notification.Name("requestInsertImage")
    /// Posted to insert a new 3×2 table at the cursor (Insert > Table menu + toolbar button, Cmd+Shift+D)
    static let requestInsertTable = Notification.Name("requestInsertTable")
    /// Posted to open the equation dialog (Insert > Equation menu + toolbar button, Cmd+Shift+E)
    static let requestInsertEquation = Notification.Name("requestInsertEquation")
    /// Posted by SectionSyncService the moment DocumentManager.isGettingStartedModified()
    /// transitions false -> true, so the UI layer can surface a toast. A notification (rather
    /// than a direct call through SectionSyncService's existing weak `editorState` back-
    /// reference) keeps this UI-layer concern -- toast visibility -- out of the sync service,
    /// which otherwise has no business touching view state.
    static let gettingStartedEdited = Notification.Name("gettingStartedEdited")
}

enum EditorMode: String, CaseIterable {
    case wysiwyg = "WYSIWYG"
    case source = "Source"
}

/// Zoom mode for section navigation
/// - full: Shows section + all descendants (default behavior)
/// - shallow: Shows section + only direct pseudo-section children
enum ZoomMode {
    case full
    case shallow
}

/// Content state machine - replaces multiple boolean flags for zoom/enforcement transitions
enum EditorContentState {
    case idle
    case zoomTransition
    case hierarchyEnforcement
    case bibliographyUpdate
    case editorTransition  // During Milkdown ↔ CodeMirror switch
    case dragReorder       // During sidebar drag-drop reorder
    case projectSwitch     // During project switch (prevents old content bleed)
    case annotationEdit    // During sidebar annotation text edit (prevents feedback loop)
    /// During a unified-undo structural op / undo / redo sequence
    /// (docs/plans/patient-rewinding-clockwork.md §4.4) -- StructuralUndoController.swift.
    case structuralUndo
}
