//
//  ContentView+UITestTriggers.swift
//  final final
//
//  UI-TEST-ONLY, DEBUG builds only (see `UITestingDeleteTrigger`): points the delete trigger at this view's own sidebar action.
//

#if DEBUG

import SwiftUI

extension ContentView {
    /// Installs the delete and duplicate triggers for this window's editor state. The actions they run are
    /// `deleteSectionFromSidebar` and `duplicateSectionFromSidebar`, the ones the sidebar's context menu calls.
    /// No-op unless `TestMode.isUITesting`.
    @MainActor
    func installUITestingDeleteTrigger() {
        guard TestMode.isUITesting else { return }
        UITestingDeleteTrigger.shared.install(editorState: editorState, perform: { sectionId in
            deleteSectionFromSidebar(sectionId)
        }, performDuplicate: { sectionId in
            duplicateSectionFromSidebar(sectionId)
        })
    }
}

#endif
