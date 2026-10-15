//
//  ContentView+UITestTriggers.swift
//  final final
//
//  UI-TEST-ONLY, DEBUG builds only (see `UITestingDeleteTrigger`): points the delete trigger at this view's own sidebar action.
//

#if DEBUG

import SwiftUI

extension ContentView {
    /// Installs the delete trigger for this window's editor state. The action it runs is `deleteSectionFromSidebar`, the one the
    /// sidebar's context menu calls. No-op unless `TestMode.isUITesting`.
    @MainActor
    func installUITestingDeleteTrigger() {
        guard TestMode.isUITesting else { return }
        UITestingDeleteTrigger.shared.install(editorState: editorState) { sectionId in
            deleteSectionFromSidebar(sectionId)
        }
    }
}

#endif
