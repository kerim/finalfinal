//
//  ContentView+MarkdownBlockWriter.swift
//  final final
//
//  t-94369a83 Phase 4a, plan v2 section 1(a) and 1(e): what ContentView does when CodeMirror's WebView becomes ready, for
//  the per-block Markdown writer (`MarkdownBlockWriter`, `BlockSyncService.ensureWriter`).
//

import SwiftUI

extension ContentView {

    /// Called from CodeMirror's `onWebViewReady` (`ContentView+EditorPresentation.swift`). The freshly mounted Markdown editor
    /// is about to be handed its text (`batchInitialize`), which comes from the stored rows.
    ///
    /// 1. `noteLoaded`: the per-block writer compares with the stored rows from here.
    /// 2. `ensureWriter`: a block-sync writer for this project, WITHOUT a WebView. A writer is normally installed by Milkdown's
    ///    `onWebViewReady` (`configure`) or a project switch's open tail (`reconfigure`, which runs in both modes), and the
    ///    app always starts in Rich Text (`EditorViewState.editorMode` defaults to `.wysiwyg`), so today this finds a live
    ///    writer and does nothing. It is a guarded safety net for any path that reaches Markdown without one: it is a no-op
    ///    while a close, switch or quit holds the editor, while the editor state still names another project (between a
    ///    switch's open and its tail), and when a live writer for this database and project exists.
    ///
    /// Inert under the UI-test flag `FF_UI_TESTING_MD_LEGACY_REPARSE`.
    func prepareMarkdownBlockWriter() {
        Self.prepareMarkdownBlockWriter(
            editorState: editorState, documentManager: documentManager, blockSyncService: blockSyncService)
    }

    /// The same, with its inputs spelled out (a unit test drives it without a mounted view).
    @MainActor
    static func prepareMarkdownBlockWriter(
        editorState: EditorViewState, documentManager: DocumentManager, blockSyncService: BlockSyncService
    ) {
        let writer = editorState.markdownWriter
        guard writer.isEnabled else { return }
        writer.noteLoaded(text: editorState.sourceContent, pid: editorState.currentProjectId)
        guard let database = documentManager.projectDatabase, let projectId = documentManager.projectId else { return }
        blockSyncService.ensureWriter(
            database: database,
            projectId: projectId,
            lifecycleActive: editorState.activeLifecycle != nil,
            editorProjectId: editorState.currentProjectId)
    }
}
