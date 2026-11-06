//
//  EditorViewState+TransitionHolds.swift
//  final final
//
//  Phase 5 job A7, slice 3 (design a7-a10-design.md, sections 3 "Holds" and 5; plan A4 note): a command pressed while a transition runs is
//  HELD and runs afterwards, never dropped (floor rules 2 and 5, UX contract 4.2):
//    - a zoom in or out, or a heading Cmd-click, pressed while the editor switches between Rich Text and Markdown or while another zoom
//      runs: held here (`holdZoomUntilTransitionEnds`), "Finishing the last change…" after one second, run when the transition is over
//      and, after a switch to Markdown, when the Markdown page is ready (job A5's `awaitMarkdownPage`);
//    - Cmd-/ pressed during a zoom: held by the existing switch hold (`holdModeToggleUntilStructuralWorkEnds`, whose wait now covers a
//      zoom too).
//  A zoom pressed during a close, quit or project switch is ignored like the mode switch (`performUserZoomIn/Out`'s first guard), the
//  model's `P5_Abort_Switch_Zoom` hazard.
//

import Foundation

extension EditorViewState {
    /// True while a zoom must wait: a switch between Rich Text and Markdown or a zoom is under way (a carried zoom keeps `contentState`
    /// `.idle` for its first steps, hence `zoomRunning`), or the Markdown page of a switch is not mounted yet.
    var zoomMustWaitForTransition: Bool {
        switch contentState {
        case .editorTransition, .zoomTransition: return true
        default: return transitionHolds.zoomRunning || transitionHolds.switchRunning || markdownPageLoading
        }
    }

    /// True while a switch between Rich Text and Markdown must wait for a zoom (Cmd-/ pressed during a zoom).
    var modeToggleMustWaitForZoom: Bool {
        contentState == .zoomTransition || transitionHolds.zoomRunning
    }

    /// Holds `run` (a user zoom, or a heading Cmd-click to be decided again) until no transition runs. One held zoom at a time: a newer press
    /// replaces an older one (the last wish wins). "Finishing the last change…" shows after one second and goes when the held zoom starts.
    /// Dropped with the project when a close, quit or project switch begins meanwhile.
    func holdZoomUntilTransitionEnds(_ run: @escaping @MainActor () -> Void) {
        transitionHolds.heldZoom = run
        guard transitionHolds.heldZoomTask == nil else {
            DebugLog.log(.zoom, "[ZoomClick] held zoom replaced by a newer press")
            return
        }
        DebugLog.alwaysPersisted("[ZoomClick] zoom held: a transition is running (contentState=\(contentState))")
        transitionHolds.heldZoomTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let toast = DelayedProgressToast(toastCenter: self.toastCenter, message: DelayedProgressToast.finishingMessage)
            defer { toast.stop() }
            await self.waitUntilZoomMayRun()
            let held = self.transitionHolds.heldZoom
            self.transitionHolds.heldZoom = nil
            self.transitionHolds.heldZoomTask = nil
            guard self.activeLifecycle == nil, !self.structuralGate.isClosedToNewWork else {
                DebugLog.log(.lifecycle, "[ZoomClick] held zoom dropped: a close, quit or switch started while it waited")
                return
            }
            DebugLog.alwaysPersisted("[ZoomClick] held zoom runs")
            held?()
        }
    }

    /// Waits until no switch or zoom runs and, after a switch to Markdown, until the page is ready (bounded by the page wait: a page that
    /// never comes stops being waited for). Returns early when a close, quit or project switch begins.
    private func waitUntilZoomMayRun() async {
        var pageWaitGaveUp = false
        while true {
            guard activeLifecycle == nil, !structuralGate.isClosedToNewWork else { return }
            if markdownPageLoading, !pageWaitGaveUp {
                pageWaitGaveUp = await awaitMarkdownPage(timeout: Self.markdownPageWaitTimeout) == .timedOut
                continue
            }
            switch contentState {
            case .editorTransition, .zoomTransition: break
            default: if !transitionHolds.zoomRunning, !transitionHolds.switchRunning { return }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
