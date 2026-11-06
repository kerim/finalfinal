//
//  ContentView+ZoomTransition.swift
//  final final
//
//  Phase 5 job A7: the user zoom's entry checks and the carried zoom in's tail (the zoom itself is EditorViewState+ZoomTransition.swift).
//

import SwiftUI

extension ContentView {
    /// False (logged) when a close, quit or project switch is saving the project: a zoom pressed then is ignored, like the mode switch
    /// (the A4 note; the model's `P5_Abort_Switch_Zoom`). Checked first, before any wait or hold.
    @MainActor
    func zoomMayStart(direction: String) -> Bool {
        guard editorState.activeLifecycle == nil, !editorState.structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[ZoomClick] zoom \(direction) ignored: the project is closing or switching")
            return false
        }
        return true
    }

    /// The carried zoom in and its tail. The zoom sets its own states (it stays `.idle` until its barrier has opened) and has set the
    /// ids already, so today's `pushBlockIds(for:)` is not repeated; the annotation sync stays. When the page could not begin, today's
    /// sequence runs unchanged.
    @MainActor
    func runCarriedZoomIn(_ sectionId: String, mode: ZoomMode, started: Date) {
        Task {
            if await editorState.zoomToSectionCarried(sectionId, mode: mode) {
                // The zoom is already back to `.idle` (and a rebuild may have started since): the state is not touched here.
                await annotationSyncService.syncNow(editorState.content)
            } else {
                editorState.contentState = .zoomTransition
                await editorState.zoomToSection(sectionId, mode: mode)
                await blockSyncService.pushBlockIds(for: editorState.zoomedBlockRange)
                await annotationSyncService.syncNow(editorState.content)
                editorState.contentState = .idle
            }
            DebugLog.log(.zoom, "[ZoomClick] performUserZoomIn tail complete in \(Date().timeIntervalSince(started))s")
        }
    }
}
