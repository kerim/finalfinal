//
//  ContentView+AnnotationDisplay.swift
//  final final
//
//  The view's side of publishing the annotation display state when a project is opened.
//

import SwiftUI

extension ContentView {

    /// Delivers the annotation display state to THIS window's editors, and only this window's:
    /// it posts through `AnnotationDisplayBroadcast` carrying this window's
    /// `EditorViewState.windowToken`. Handed to `EditorViewState.runProjectOpenSequence`, which
    /// decides WHEN to publish (after the load and Focus Mode's override, and again after the new
    /// content is in the editor); see that function for why an explicit publish is needed at all.
    var annotationDisplayPublisher: @MainActor ([AnnotationType: AnnotationDisplayMode], Bool, Bool) -> Void {
        let windowToken = editorState.windowToken
        return { modes, isPanelOnly, hideCompletedTasks in
            AnnotationDisplayBroadcast.post(
                modes: modes,
                isPanelOnly: isPanelOnly,
                hideCompletedTasks: hideCompletedTasks,
                windowToken: windowToken
            )
        }
    }
}
